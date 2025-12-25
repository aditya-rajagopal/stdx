const std = @import("std");
const win = std.os.windows;
const Guid = win.GUID;
const win32 = @import("win32.zig");
const IUnknown = win32.IUnknown;
const HRESULT = win.HRESULT;
const BOOL = win.BOOL;
const HINSTANCE = win.HINSTANCE;

pub const PlaybackParams = struct {
    play_begin: u32 = 0,
    play_length: u32 = 0,
    loop_begin: u32 = 0,
    loop_length: u32 = 0,
    loop_count: u32 = 0,
};

pub const MaxConcurrentVoices = 16;

dll: HINSTANCE = undefined,
x_audio2: *IXAudio2 = undefined,
mastering_voice: *IXAudio2MasteringVoice = undefined,
// TODO(io): Do we need different voice stacks for SFX and Music?
voices: [MaxConcurrentVoices]XAudioVoice = undefined,
callback: StopOnEndCallback = undefined,

pub const XAudioVoice = struct {
    source: *IXAudio2SourceVoice = undefined,
    playing: bool = false,
    buffer: ?[]const u8 = null,
};

const Self = @This();

pub const Error = error{
    FailedToInitializeCOM,
    FailedToLoadXAudio2DLL,
    FailedToCreateXAudio2,
    FailedToCreateMasteringVoice,
    FailedToCreateVoice,
};

const PFNXAudio2Create = *const fn (
    ppXaudio2: *?*IXAudio2,
    flags: FLAGS,
    XAudio2Processor: win.UINT,
) callconv(.winapi) HRESULT;

// TODO(sound): Do we need any other type of callbacks for different kinds of voices?
const StopOnEndCallback = extern struct {
    vtable: *const IXAudio2VoiceCallback.VTable = &default,

    pub const default = IXAudio2VoiceCallback.VTable{
        .OnStreamEnd = _onStreamEnd,
        .OnBufferStart = _onBufferStart,
        .OnVoiceProcessingPassStart = _onVoiceProcessingPassStart,
        .OnVoiceProcessingPassEnd = _onVoiceProcessingPassEnd,
        .OnBufferEnd = _onBufferEnd,
        .OnLoopEnd = _onLoopEnd,
        .OnVoiceError = _onVoiceError,
    };

    fn _onBufferEnd(_: *IXAudio2VoiceCallback, context: ?*anyopaque) callconv(.winapi) void {
        const voice: *XAudioVoice = @ptrCast(@alignCast(context));
        _ = voice.source.Stop(0, XAUDIO2_COMMIT_NOW);
        _ = voice.source.FlushSourceBuffers();
        voice.buffer = null;
        voice.playing = false;
    }

    fn _onBufferStart(_: *IXAudio2VoiceCallback, _: ?*anyopaque) callconv(.winapi) void {}
    fn _onStreamEnd(_: *IXAudio2VoiceCallback) callconv(.winapi) void {}
    fn _onVoiceProcessingPassStart(_: *IXAudio2VoiceCallback, _: u32) callconv(.winapi) void {}
    fn _onVoiceProcessingPassEnd(_: *IXAudio2VoiceCallback) callconv(.winapi) void {}
    fn _onLoopEnd(_: *IXAudio2VoiceCallback, _: ?*anyopaque) callconv(.winapi) void {}
    fn _onVoiceError(_: *IXAudio2VoiceCallback, _: ?*anyopaque, _: HRESULT) callconv(.winapi) void {}
};

pub fn init(audio_engine: *Self) Error!void {
    // TODO(adi): Should the sound system be configurable
    // TODO(adi): Should we use COINIT_SPEED_OVER_MEMORY?
    var result = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED | win32.COINIT_SPEED_OVER_MEMORY);
    errdefer win32.CoUninitialize();
    if (result != win32.S_OK) {
        return Error.FailedToInitializeCOM;
    }

    audio_engine.dll = win32.LoadLibraryA("xaudio2_9.dll") orelse return Error.FailedToLoadXAudio2DLL;
    errdefer _ = win32.FreeLibrary(audio_engine.dll);

    const xAudio2Create: PFNXAudio2Create = @ptrCast(win32.GetProcAddress(audio_engine.dll, "XAudio2Create") orelse return Error.FailedToLoadXAudio2DLL);
    var x_audio2_interface: ?*IXAudio2 = undefined;
    result = xAudio2Create(&x_audio2_interface, FLAGS{}, XAUDIO2_ANY_PROCESSOR);
    if (result != win32.S_OK) {
        return Error.FailedToCreateXAudio2;
    }

    audio_engine.x_audio2 = x_audio2_interface orelse return Error.FailedToCreateXAudio2;
    errdefer audio_engine.x_audio2.Relese();

    var mastering_voice_interface: ?*IXAudio2MasteringVoice = undefined;
    result = audio_engine.x_audio2.CreateMasteringVoice(
        &mastering_voice_interface,
        2,
        44100,
        0,
        null,
        null,
        AUDIO_STREAM_CATEGORY.GameEffects,
    );
    if (result != win32.S_OK) {
        return Error.FailedToCreateMasteringVoice;
    }
    audio_engine.mastering_voice = mastering_voice_interface orelse return Error.FailedToCreateMasteringVoice;

    // TODO(adi): idk if this needs to be configurable
    const wave_format: WAVEFORMATEX = .default;

    audio_engine.callback = .{};

    for (&audio_engine.voices) |*voice| {
        var v: ?*IXAudio2SourceVoice = undefined;
        result = audio_engine.x_audio2.CreateSourceVoice(
            &v,
            &wave_format,
            0,
            XAUDIO2_DEFAULT_FREQ_RATIO,
            @ptrCast(@alignCast(&audio_engine.callback)),
            null,
            null,
        );

        if (result != win32.S_OK) {
            return Error.FailedToCreateVoice;
        }

        voice.* = .{};
        voice.source = v orelse return Error.FailedToCreateVoice;
        result = voice.source.SetVolume(1.0, XAUDIO2_COMMIT_NOW);
        if (result != win32.S_OK) {
            // TODO(io):
            std.log.info("Failed to set volume: {d}", .{result});
        }
    }
}

pub fn deinit(self: *Self) void {
    self.x_audio2.Relese();
    _ = win32.FreeLibrary(self.dll);
    win32.CoUninitialize();
}

fn getAvailableVoice(self: *Self) ?*XAudioVoice {
    for (&self.voices) |*voice| {
        if (!voice.playing) {
            return voice;
        }
    }
    return null;
}

pub fn playSound(self: *Self, data: []const u8, params: PlaybackParams) bool {
    // TODO(sound): if we are full on voices we are just not going to play the sound.
    // Should we do something else?
    const voice: *XAudioVoice = getAvailableVoice(self) orelse return false;
    voice.buffer = data;
    const x_audio_buffer = XAUDIO2_BUFFER{
        .Flags = XAUDIO2_END_OF_STREAM,
        .AudioBytes = @truncate(data.len),
        .pAudioData = @ptrCast(data.ptr),
        .PlayBegin = params.play_begin,
        .PlayLength = params.play_length,
        .LoopBegin = params.loop_begin,
        .LoopLength = params.loop_length,
        .LoopCount = params.loop_count,
        .pContext = @ptrCast(voice),
    };
    var result = voice.source.SubmitSourceBuffer(&x_audio_buffer, null);
    if (result != win32.S_OK) {
        // TODO(io): remove this log and should go into the IO queue
        std.log.info("Failed to submit source buffer: {d}", .{result});
        return false;
    }
    result = voice.source.Start(0, XAUDIO2_COMMIT_NOW);
    if (result != win32.S_OK) {
        // TODO(io): remove this log and should go into the IO queue
        std.log.info("Failed to start source buffer: {d}", .{result});
        return false;
    }
    voice.playing = true;
    return true;
}

pub fn stopSound(self: *Self, data: []const u8) void {
    for (&self.voices) |*voice| {
        if (voice.buffer) |buffer| {
            if (buffer.ptr == data.ptr) {
                voice.Stop(0, XAUDIO2_COMMIT_NOW);
                voice.FlushSourceBuffers();
                voice.buffer = null;
                voice.playing = false;
                return;
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------------------
// XAudio2 Win32 API
// ------------------------------------------------------------------------------------------------------------

// TODO(adi): Do we need XAPO? https://github.com/marlersoft/zigwin32/blob/main/win32/media/audio/xaudio2.zig

pub const WAVE_FORMAT_PCM = @as(u32, 1);

const WAVEFORMATEX = extern struct {
    wFormatTag: win.WORD,
    nChannels: win.WORD,
    nSamplesPerSec: win.DWORD,
    nAvgBytesPerSec: win.DWORD,
    nBlockAlign: win.WORD,
    wBitsPerSample: win.WORD,
    cbSize: win.WORD,

    pub const default: WAVEFORMATEX = .{
        .wFormatTag = WAVE_FORMAT_PCM,
        .nChannels = 2,
        .nSamplesPerSec = 44100,
        .nAvgBytesPerSec = 4 * 44100, // nSamplesPerSec * nBlockAlign
        .nBlockAlign = 4, // num_channels * bits_per_sample / 8
        .wBitsPerSample = 16,
        .cbSize = 0,
    };
};

pub const FLAGS = packed struct(c_uint) {
    DEBUG_ENGINE: bool = false,
    VOICE_NOPITCH: bool = false,
    VOICE_NOSRC: bool = false,
    VOICE_USEFILTER: bool = false,
    __unused4: bool = false,
    PLAY_TAILS: bool = false,
    END_OF_STREAM: bool = false,
    SEND_USEFILTER: bool = false,
    VOICE_NOSAMPLESPLAYED: bool = false,
    __unused9: bool = false,
    __unused10: bool = false,
    __unused11: bool = false,
    __unused12: bool = false,
    STOP_ENGINE_WHEN_IDLE: bool = false,
    __unused14: bool = false,
    @"1024_QUANTUM": bool = false,
    NO_VIRTUAL_AUDIO_CLIENT: bool = false,
    __unused: u15 = 0,
};

pub const AUDIO_STREAM_CATEGORY = enum(i32) {
    Other = 0,
    ForegroundOnlyMedia = 1,
    Communications = 3,
    Alerts = 4,
    SoundEffects = 5,
    GameEffects = 6,
    GameMedia = 7,
    GameChat = 8,
    Speech = 9,
    Movie = 10,
    Media = 11,
    FarFieldSpeech = 12,
    UniformSpeech = 13,
    VoiceTyping = 14,
};
pub const AudioCategory_Other = AUDIO_STREAM_CATEGORY.Other;
pub const AudioCategory_ForegroundOnlyMedia = AUDIO_STREAM_CATEGORY.ForegroundOnlyMedia;
pub const AudioCategory_Communications = AUDIO_STREAM_CATEGORY.Communications;
pub const AudioCategory_Alerts = AUDIO_STREAM_CATEGORY.Alerts;
pub const AudioCategory_SoundEffects = AUDIO_STREAM_CATEGORY.SoundEffects;
pub const AudioCategory_GameEffects = AUDIO_STREAM_CATEGORY.GameEffects;
pub const AudioCategory_GameMedia = AUDIO_STREAM_CATEGORY.GameMedia;
pub const AudioCategory_GameChat = AUDIO_STREAM_CATEGORY.GameChat;
pub const AudioCategory_Speech = AUDIO_STREAM_CATEGORY.Speech;
pub const AudioCategory_Movie = AUDIO_STREAM_CATEGORY.Movie;
pub const AudioCategory_Media = AUDIO_STREAM_CATEGORY.Media;
pub const AudioCategory_FarFieldSpeech = AUDIO_STREAM_CATEGORY.FarFieldSpeech;
pub const AudioCategory_UniformSpeech = AUDIO_STREAM_CATEGORY.UniformSpeech;
pub const AudioCategory_VoiceTyping = AUDIO_STREAM_CATEGORY.VoiceTyping;

const XAUDIO2_COMMIT_NOW = 0;

pub const XAUDIO2_VOICE_DETAILS = extern struct {
    CreationFlags: u32 align(1),
    ActiveFlags: u32 align(1),
    InputChannels: u32 align(1),
    InputSampleRate: u32 align(1),
};

pub const XAUDIO2_SEND_DESCRIPTOR = extern struct {
    Flags: u32 align(1),
    pOutputVoice: ?*IXAudio2Voice align(1),
};

pub const XAUDIO2_VOICE_SENDS = extern struct {
    SendCount: u32 align(1),
    pSends: ?*XAUDIO2_SEND_DESCRIPTOR align(1),
};

pub const XAUDIO2_EFFECT_DESCRIPTOR = extern struct {
    pEffect: ?*IUnknown align(1),
    InitialState: BOOL align(1),
    OutputChannels: u32 align(1),
};

pub const XAUDIO2_EFFECT_CHAIN = extern struct {
    EffectCount: u32 align(1),
    pEffectDescriptors: ?*XAUDIO2_EFFECT_DESCRIPTOR align(1),
};

pub const XAUDIO2_FILTER_TYPE = enum(i32) {
    LowPassFilter = 0,
    BandPassFilter = 1,
    HighPassFilter = 2,
    NotchFilter = 3,
    LowPassOnePoleFilter = 4,
    HighPassOnePoleFilter = 5,
};
pub const LowPassFilter = XAUDIO2_FILTER_TYPE.LowPassFilter;
pub const BandPassFilter = XAUDIO2_FILTER_TYPE.BandPassFilter;
pub const HighPassFilter = XAUDIO2_FILTER_TYPE.HighPassFilter;
pub const NotchFilter = XAUDIO2_FILTER_TYPE.NotchFilter;
pub const LowPassOnePoleFilter = XAUDIO2_FILTER_TYPE.LowPassOnePoleFilter;
pub const HighPassOnePoleFilter = XAUDIO2_FILTER_TYPE.HighPassOnePoleFilter;

pub const XAUDIO2_FILTER_PARAMETERS = extern struct {
    Type: XAUDIO2_FILTER_TYPE align(1),
    Frequency: f32 align(1),
    OneOverQ: f32 align(1),
};

const XAUDIO2_MAX_LOOP_COUNT = 254; // Maximum non-infinite XAUDIO2_BUFFER.LoopCount
pub const XAUDIO2_BUFFER = extern struct {
    Flags: u32 align(1),
    AudioBytes: u32 align(1),
    pAudioData: ?*const u8 align(1),
    PlayBegin: u32 align(1),
    PlayLength: u32 align(1),
    LoopBegin: u32 align(1),
    LoopLength: u32 align(1),
    LoopCount: u32 align(1),
    pContext: ?*anyopaque align(1),
};

pub const XAUDIO2_BUFFER_WMA = extern struct {
    pDecodedPacketCumulativeBytes: ?*const u32 align(1),
    PacketCount: u32 align(1),
};

pub const XAUDIO2_VOICE_STATE = extern struct {
    pCurrentBufferContext: ?*anyopaque align(1),
    BuffersQueued: u32 align(1),
    SamplesPlayed: u64 align(1),
};

pub const XAUDIO2_PERFORMANCE_DATA = extern struct {
    AudioCyclesSinceLastQuery: u64 align(1),
    TotalCyclesSinceLastQuery: u64 align(1),
    MinimumCyclesPerQuantum: u32 align(1),
    MaximumCyclesPerQuantum: u32 align(1),
    MemoryUsageInBytes: u32 align(1),
    CurrentLatencyInSamples: u32 align(1),
    GlitchesSinceEngineStarted: u32 align(1),
    ActiveSourceVoiceCount: u32 align(1),
    TotalSourceVoiceCount: u32 align(1),
    ActiveSubmixVoiceCount: u32 align(1),
    ActiveResamplerCount: u32 align(1),
    ActiveMatrixMixCount: u32 align(1),
    ActiveXmaSourceVoices: u32 align(1),
    ActiveXmaStreams: u32 align(1),
};

pub const XAUDIO2_DEBUG_CONFIGURATION = extern struct {
    TraceMask: u32 align(1),
    BreakMask: u32 align(1),
    LogThreadID: BOOL align(1),
    LogFileline: BOOL align(1),
    LogFunctionName: BOOL align(1),
    LogTiming: BOOL align(1),
};

const XAUDIO2_ANY_PROCESSOR = 0xffffffff;
const XAUDIO2_USE_DEFAULT_PROCESSOR = 0x00000000;
const XAUDIO2_DEFAULT_FREQ_RATIO = 2.0;

const XAUDIO2_END_OF_STREAM = 0x0040; // Used in XAUDIO2_BUFFER.Flags

pub const IID_IXAudio2_Value = Guid.parse("2b02e3cf-2e0b-4ec3-be45-1b2a3fe7210d");
pub const IXAudio2 = extern union {
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        RegisterForCallbacks: *const fn (
            self: *const IXAudio2,
            pCallback: ?*IXAudio2EngineCallback,
        ) callconv(.winapi) HRESULT,
        UnregisterForCallbacks: *const fn (
            self: *const IXAudio2,
            pCallback: ?*IXAudio2EngineCallback,
        ) callconv(.winapi) void,
        CreateSourceVoice: *const fn (
            self: *const IXAudio2,
            ppSourceVoice: ?*?*IXAudio2SourceVoice,
            pSourceFormat: ?*const WAVEFORMATEX,
            Flags: u32,
            MaxFrequencyRatio: f32,
            pCallback: ?*IXAudio2VoiceCallback,
            pSendList: ?*const XAUDIO2_VOICE_SENDS,
            pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
        ) callconv(.winapi) HRESULT,
        CreateSubmixVoice: *const fn (
            self: *const IXAudio2,
            ppSubmixVoice: ?*?*IXAudio2SubmixVoice,
            InputChannels: u32,
            InputSampleRate: u32,
            Flags: u32,
            ProcessingStage: u32,
            pSendList: ?*const XAUDIO2_VOICE_SENDS,
            pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
        ) callconv(.winapi) HRESULT,
        CreateMasteringVoice: *const fn (
            self: *const IXAudio2,
            ppMasteringVoice: ?*?*IXAudio2MasteringVoice,
            InputChannels: u32,
            InputSampleRate: u32,
            Flags: u32,
            szDeviceId: ?[*:0]const u16,
            pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
            StreamCategory: AUDIO_STREAM_CATEGORY,
        ) callconv(.winapi) HRESULT,
        StartEngine: *const fn (
            self: *const IXAudio2,
        ) callconv(.winapi) HRESULT,
        StopEngine: *const fn (
            self: *const IXAudio2,
        ) callconv(.winapi) void,
        CommitChanges: *const fn (
            self: *const IXAudio2,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetPerformanceData: *const fn (
            self: *const IXAudio2,
            pPerfData: ?*XAUDIO2_PERFORMANCE_DATA,
        ) callconv(.winapi) void,
        SetDebugConfiguration: *const fn (
            self: *const IXAudio2,
            pDebugConfiguration: ?*const XAUDIO2_DEBUG_CONFIGURATION,
            pReserved: ?*anyopaque,
        ) callconv(.winapi) void,
    };
    vtable: *const VTable,
    IUnknown: IUnknown,
    pub inline fn RegisterForCallbacks(self: *const IXAudio2, pCallback: ?*IXAudio2EngineCallback) HRESULT {
        return self.vtable.RegisterForCallbacks(self, pCallback);
    }
    pub inline fn UnregisterForCallbacks(self: *const IXAudio2, pCallback: ?*IXAudio2EngineCallback) void {
        return self.vtable.UnregisterForCallbacks(self, pCallback);
    }
    pub inline fn CreateSourceVoice(
        self: *const IXAudio2,
        ppSourceVoice: ?*?*IXAudio2SourceVoice,
        pSourceFormat: ?*const WAVEFORMATEX,
        Flags: u32,
        MaxFrequencyRatio: f32,
        pCallback: ?*IXAudio2VoiceCallback,
        pSendList: ?*const XAUDIO2_VOICE_SENDS,
        pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
    ) HRESULT {
        return self.vtable.CreateSourceVoice(
            self,
            ppSourceVoice,
            pSourceFormat,
            Flags,
            MaxFrequencyRatio,
            pCallback,
            pSendList,
            pEffectChain,
        );
    }
    pub inline fn CreateSubmixVoice(
        self: *const IXAudio2,
        ppSubmixVoice: ?*?*IXAudio2SubmixVoice,
        InputChannels: u32,
        InputSampleRate: u32,
        Flags: u32,
        ProcessingStage: u32,
        pSendList: ?*const XAUDIO2_VOICE_SENDS,
        pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
    ) HRESULT {
        return self.vtable.CreateSubmixVoice(
            self,
            ppSubmixVoice,
            InputChannels,
            InputSampleRate,
            Flags,
            ProcessingStage,
            pSendList,
            pEffectChain,
        );
    }
    pub inline fn CreateMasteringVoice(
        self: *const IXAudio2,
        ppMasteringVoice: ?*?*IXAudio2MasteringVoice,
        InputChannels: u32,
        InputSampleRate: u32,
        Flags: u32,
        szDeviceId: ?[*:0]const u16,
        pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
        StreamCategory: AUDIO_STREAM_CATEGORY,
    ) HRESULT {
        return self.vtable.CreateMasteringVoice(
            self,
            ppMasteringVoice,
            InputChannels,
            InputSampleRate,
            Flags,
            szDeviceId,
            pEffectChain,
            StreamCategory,
        );
    }
    pub inline fn StartEngine(self: *const IXAudio2) HRESULT {
        return self.vtable.StartEngine(self);
    }
    pub inline fn StopEngine(self: *const IXAudio2) void {
        return self.vtable.StopEngine(self);
    }
    pub inline fn CommitChanges(self: *const IXAudio2, OperationSet: u32) HRESULT {
        return self.vtable.CommitChanges(self, OperationSet);
    }
    pub inline fn GetPerformanceData(self: *const IXAudio2, pPerfData: ?*XAUDIO2_PERFORMANCE_DATA) void {
        return self.vtable.GetPerformanceData(self, pPerfData);
    }
    pub inline fn SetDebugConfiguration(
        self: *const IXAudio2,
        pDebugConfiguration: ?*const XAUDIO2_DEBUG_CONFIGURATION,
        pReserved: ?*anyopaque,
    ) void {
        return self.vtable.SetDebugConfiguration(self, pDebugConfiguration, pReserved);
    }
    pub inline fn Relese(self: *const IXAudio2) void {
        _ = self.vtable.base.Release(&self.IUnknown);
    }
};

pub const IXAudio2EngineCallback = extern union {
    pub const VTable = extern struct {
        OnProcessingPassStart: *const fn (
            self: *const IXAudio2EngineCallback,
        ) callconv(.winapi) void,
        OnProcessingPassEnd: *const fn (
            self: *const IXAudio2EngineCallback,
        ) callconv(.winapi) void,
        OnCriticalError: *const fn (
            self: *const IXAudio2EngineCallback,
            Error: HRESULT,
        ) callconv(.winapi) void,
    };
    vtable: *const VTable,
    pub inline fn OnProcessingPassStart(self: *const IXAudio2EngineCallback) void {
        return self.vtable.OnProcessingPassStart(self);
    }
    pub inline fn OnProcessingPassEnd(self: *const IXAudio2EngineCallback) void {
        return self.vtable.OnProcessingPassEnd(self);
    }
    pub inline fn OnCriticalError(self: *const IXAudio2EngineCallback, err: HRESULT) void {
        return self.vtable.OnCriticalError(self, err);
    }
};

pub const IXAudio2Voice = extern union {
    pub const VTable = extern struct {
        GetVoiceDetails: *const fn (
            self: *const IXAudio2Voice,
            pVoiceDetails: ?*XAUDIO2_VOICE_DETAILS,
        ) callconv(.winapi) void,
        SetOutputVoices: *const fn (
            self: *const IXAudio2Voice,
            pSendList: ?*const XAUDIO2_VOICE_SENDS,
        ) callconv(.winapi) HRESULT,
        SetEffectChain: *const fn (
            self: *const IXAudio2Voice,
            pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN,
        ) callconv(.winapi) HRESULT,
        EnableEffect: *const fn (
            self: *const IXAudio2Voice,
            EffectIndex: u32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        DisableEffect: *const fn (
            self: *const IXAudio2Voice,
            EffectIndex: u32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetEffectState: *const fn (
            self: *const IXAudio2Voice,
            EffectIndex: u32,
            pEnabled: ?*BOOL,
        ) callconv(.winapi) void,
        SetEffectParameters: *const fn (
            self: *const IXAudio2Voice,
            EffectIndex: u32,
            // TODO: what to do with BytesParamIndex 2?
            pParameters: ?*const anyopaque,
            ParametersByteSize: u32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetEffectParameters: *const fn (
            self: *const IXAudio2Voice,
            EffectIndex: u32,
            // TODO: what to do with BytesParamIndex 2?
            pParameters: ?*anyopaque,
            ParametersByteSize: u32,
        ) callconv(.winapi) HRESULT,
        SetFilterParameters: *const fn (
            self: *const IXAudio2Voice,
            pParameters: ?*const XAUDIO2_FILTER_PARAMETERS,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetFilterParameters: *const fn (
            self: *const IXAudio2Voice,
            pParameters: ?*XAUDIO2_FILTER_PARAMETERS,
        ) callconv(.winapi) void,
        SetOutputFilterParameters: *const fn (
            self: *const IXAudio2Voice,
            pDestinationVoice: ?*IXAudio2Voice,
            pParameters: ?*const XAUDIO2_FILTER_PARAMETERS,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetOutputFilterParameters: *const fn (
            self: *const IXAudio2Voice,
            pDestinationVoice: ?*IXAudio2Voice,
            pParameters: ?*XAUDIO2_FILTER_PARAMETERS,
        ) callconv(.winapi) void,
        SetVolume: *const fn (
            self: *IXAudio2Voice,
            Volume: f32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetVolume: *const fn (
            self: *const IXAudio2Voice,
            pVolume: ?*f32,
        ) callconv(.winapi) void,
        SetChannelVolumes: *const fn (
            self: *const IXAudio2Voice,
            Channels: u32,
            pVolumes: [*]const f32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetChannelVolumes: *const fn (
            self: *const IXAudio2Voice,
            Channels: u32,
            pVolumes: [*]f32,
        ) callconv(.winapi) void,
        SetOutputMatrix: *const fn (
            self: *const IXAudio2Voice,
            pDestinationVoice: ?*IXAudio2Voice,
            SourceChannels: u32,
            DestinationChannels: u32,
            pLevelMatrix: ?*const f32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetOutputMatrix: *const fn (
            self: *const IXAudio2Voice,
            pDestinationVoice: ?*IXAudio2Voice,
            SourceChannels: u32,
            DestinationChannels: u32,
            pLevelMatrix: ?*f32,
        ) callconv(.winapi) void,
        DestroyVoice: *const fn (
            self: *const IXAudio2Voice,
        ) callconv(.winapi) void,
    };
    vtable: *const VTable,
    pub inline fn GetVoiceDetails(self: *const IXAudio2Voice, pVoiceDetails: ?*XAUDIO2_VOICE_DETAILS) void {
        return self.vtable.GetVoiceDetails(self, pVoiceDetails);
    }
    pub inline fn SetOutputVoices(self: *const IXAudio2Voice, pSendList: ?*const XAUDIO2_VOICE_SENDS) HRESULT {
        return self.vtable.SetOutputVoices(self, pSendList);
    }
    pub inline fn SetEffectChain(self: *const IXAudio2Voice, pEffectChain: ?*const XAUDIO2_EFFECT_CHAIN) HRESULT {
        return self.vtable.SetEffectChain(self, pEffectChain);
    }
    pub inline fn EnableEffect(self: *const IXAudio2Voice, EffectIndex: u32, OperationSet: u32) HRESULT {
        return self.vtable.EnableEffect(self, EffectIndex, OperationSet);
    }
    pub inline fn DisableEffect(self: *const IXAudio2Voice, EffectIndex: u32, OperationSet: u32) HRESULT {
        return self.vtable.DisableEffect(self, EffectIndex, OperationSet);
    }
    pub inline fn GetEffectState(self: *const IXAudio2Voice, EffectIndex: u32, pEnabled: ?*BOOL) void {
        return self.vtable.GetEffectState(self, EffectIndex, pEnabled);
    }
    pub inline fn SetEffectParameters(
        self: *const IXAudio2Voice,
        EffectIndex: u32,
        pParameters: ?*const anyopaque,
        ParametersByteSize: u32,
        OperationSet: u32,
    ) HRESULT {
        return self.vtable.SetEffectParameters(self, EffectIndex, pParameters, ParametersByteSize, OperationSet);
    }
    pub inline fn GetEffectParameters(
        self: *const IXAudio2Voice,
        EffectIndex: u32,
        pParameters: ?*anyopaque,
        ParametersByteSize: u32,
    ) HRESULT {
        return self.vtable.GetEffectParameters(self, EffectIndex, pParameters, ParametersByteSize);
    }
    pub inline fn SetFilterParameters(
        self: *const IXAudio2Voice,
        pParameters: ?*const XAUDIO2_FILTER_PARAMETERS,
        OperationSet: u32,
    ) HRESULT {
        return self.vtable.SetFilterParameters(self, pParameters, OperationSet);
    }
    pub inline fn GetFilterParameters(self: *const IXAudio2Voice, pParameters: ?*XAUDIO2_FILTER_PARAMETERS) void {
        return self.vtable.GetFilterParameters(self, pParameters);
    }
    pub inline fn SetOutputFilterParameters(
        self: *const IXAudio2Voice,
        pDestinationVoice: ?*IXAudio2Voice,
        pParameters: ?*const XAUDIO2_FILTER_PARAMETERS,
        OperationSet: u32,
    ) HRESULT {
        return self.vtable.SetOutputFilterParameters(self, pDestinationVoice, pParameters, OperationSet);
    }
    pub inline fn GetOutputFilterParameters(
        self: *const IXAudio2Voice,
        pDestinationVoice: ?*IXAudio2Voice,
        pParameters: ?*XAUDIO2_FILTER_PARAMETERS,
    ) void {
        return self.vtable.GetOutputFilterParameters(self, pDestinationVoice, pParameters);
    }
    pub inline fn SetVolume(self: *IXAudio2Voice, Volume: f32, OperationSet: u32) HRESULT {
        return self.vtable.SetVolume(self, Volume, OperationSet);
    }
    pub inline fn GetVolume(self: *const IXAudio2Voice, pVolume: ?*f32) void {
        return self.vtable.GetVolume(self, pVolume);
    }
    pub inline fn SetChannelVolumes(
        self: *const IXAudio2Voice,
        Channels: u32,
        pVolumes: [*]const f32,
        OperationSet: u32,
    ) HRESULT {
        return self.vtable.SetChannelVolumes(self, Channels, pVolumes, OperationSet);
    }
    pub inline fn GetChannelVolumes(self: *const IXAudio2Voice, Channels: u32, pVolumes: [*]f32) void {
        return self.vtable.GetChannelVolumes(self, Channels, pVolumes);
    }
    pub inline fn SetOutputMatrix(
        self: *const IXAudio2Voice,
        pDestinationVoice: ?*IXAudio2Voice,
        SourceChannels: u32,
        DestinationChannels: u32,
        pLevelMatrix: ?*const f32,
        OperationSet: u32,
    ) HRESULT {
        return self.vtable.SetOutputMatrix(
            self,
            pDestinationVoice,
            SourceChannels,
            DestinationChannels,
            pLevelMatrix,
            OperationSet,
        );
    }
    pub inline fn GetOutputMatrix(
        self: *const IXAudio2Voice,
        pDestinationVoice: ?*IXAudio2Voice,
        SourceChannels: u32,
        DestinationChannels: u32,
        pLevelMatrix: ?*f32,
    ) void {
        return self.vtable.GetOutputMatrix(
            self,
            pDestinationVoice,
            SourceChannels,
            DestinationChannels,
            pLevelMatrix,
        );
    }
    pub inline fn DestroyVoice(self: *const IXAudio2Voice) void {
        return self.vtable.DestroyVoice(self);
    }
};

pub const IXAudio2SourceVoice = extern union {
    pub const VTable = extern struct {
        base: IXAudio2Voice.VTable,
        Start: *const fn (
            self: *IXAudio2SourceVoice,
            Flags: u32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        Stop: *const fn (
            self: *const IXAudio2SourceVoice,
            Flags: u32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        SubmitSourceBuffer: *const fn (
            self: *IXAudio2SourceVoice,
            pBuffer: ?*const XAUDIO2_BUFFER,
            pBufferWMA: ?*const XAUDIO2_BUFFER_WMA,
        ) callconv(.winapi) HRESULT,
        FlushSourceBuffers: *const fn (
            self: *const IXAudio2SourceVoice,
        ) callconv(.winapi) HRESULT,
        Discontinuity: *const fn (
            self: *const IXAudio2SourceVoice,
        ) callconv(.winapi) HRESULT,
        ExitLoop: *const fn (
            self: *const IXAudio2SourceVoice,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetState: *const fn (
            self: *const IXAudio2SourceVoice,
            pVoiceState: ?*XAUDIO2_VOICE_STATE,
            Flags: u32,
        ) callconv(.winapi) void,
        SetFrequencyRatio: *const fn (
            self: *const IXAudio2SourceVoice,
            Ratio: f32,
            OperationSet: u32,
        ) callconv(.winapi) HRESULT,
        GetFrequencyRatio: *const fn (
            self: *const IXAudio2SourceVoice,
            pRatio: ?*f32,
        ) callconv(.winapi) void,
        SetSourceSampleRate: *const fn (
            self: *const IXAudio2SourceVoice,
            NewSourceSampleRate: u32,
        ) callconv(.winapi) HRESULT,
    };
    vtable: *const VTable,
    IXAudio2Voice: IXAudio2Voice,
    pub inline fn Start(self: *IXAudio2SourceVoice, Flags: u32, OperationSet: u32) HRESULT {
        return self.vtable.Start(self, Flags, OperationSet);
    }
    pub inline fn Stop(self: *const IXAudio2SourceVoice, Flags: u32, OperationSet: u32) HRESULT {
        return self.vtable.Stop(self, Flags, OperationSet);
    }
    pub inline fn SubmitSourceBuffer(
        self: *IXAudio2SourceVoice,
        pBuffer: ?*const XAUDIO2_BUFFER,
        pBufferWMA: ?*const XAUDIO2_BUFFER_WMA,
    ) HRESULT {
        return self.vtable.SubmitSourceBuffer(self, pBuffer, pBufferWMA);
    }
    pub inline fn FlushSourceBuffers(self: *const IXAudio2SourceVoice) HRESULT {
        return self.vtable.FlushSourceBuffers(self);
    }
    pub inline fn Discontinuity(self: *const IXAudio2SourceVoice) HRESULT {
        return self.vtable.Discontinuity(self);
    }
    pub inline fn ExitLoop(self: *const IXAudio2SourceVoice, OperationSet: u32) HRESULT {
        return self.vtable.ExitLoop(self, OperationSet);
    }
    pub inline fn GetState(self: *const IXAudio2SourceVoice, pVoiceState: ?*XAUDIO2_VOICE_STATE, Flags: u32) void {
        return self.vtable.GetState(self, pVoiceState, Flags);
    }
    pub inline fn SetFrequencyRatio(self: *const IXAudio2SourceVoice, Ratio: f32, OperationSet: u32) HRESULT {
        return self.vtable.SetFrequencyRatio(self, Ratio, OperationSet);
    }
    pub inline fn GetFrequencyRatio(self: *const IXAudio2SourceVoice, pRatio: ?*f32) void {
        return self.vtable.GetFrequencyRatio(self, pRatio);
    }
    pub inline fn SetSourceSampleRate(self: *const IXAudio2SourceVoice, NewSourceSampleRate: u32) HRESULT {
        return self.vtable.SetSourceSampleRate(self, NewSourceSampleRate);
    }

    pub inline fn SetVolume(self: *IXAudio2SourceVoice, Volume: f32, OperationSet: u32) HRESULT {
        return self.IXAudio2Voice.SetVolume(Volume, OperationSet);
    }
};

pub const IXAudio2SubmixVoice = extern union {
    pub const VTable = extern struct {
        base: IXAudio2Voice.VTable,
    };
    vtable: *const VTable,
    IXAudio2Voice: IXAudio2Voice,
};

pub const IXAudio2MasteringVoice = extern union {
    pub const VTable = extern struct {
        base: IXAudio2Voice.VTable,
        GetChannelMask: *const fn (
            self: *const IXAudio2MasteringVoice,
            pChannelmask: ?*u32,
        ) callconv(.winapi) HRESULT,
    };
    vtable: *const VTable,
    IXAudio2Voice: IXAudio2Voice,
    pub inline fn GetChannelMask(self: *const IXAudio2MasteringVoice, pChannelmask: ?*u32) HRESULT {
        return self.vtable.GetChannelMask(self, pChannelmask);
    }
};

pub const IXAudio2VoiceCallback = extern union {
    pub const VTable = extern struct {
        OnVoiceProcessingPassStart: *const fn (
            self: *IXAudio2VoiceCallback,
            BytesRequired: u32,
        ) callconv(.winapi) void = _onVoiceProcessingPassStart,
        OnVoiceProcessingPassEnd: *const fn (
            self: *IXAudio2VoiceCallback,
        ) callconv(.winapi) void = _onVoiceProcessingPassEnd,
        OnStreamEnd: *const fn (
            self: *IXAudio2VoiceCallback,
        ) callconv(.winapi) void = _onStreamEnd,
        OnBufferStart: *const fn (
            self: *IXAudio2VoiceCallback,
            pBufferContext: ?*anyopaque,
        ) callconv(.winapi) void = _onBufferStart,
        OnBufferEnd: *const fn (
            self: *IXAudio2VoiceCallback,
            pBufferContext: ?*anyopaque,
        ) callconv(.winapi) void = _onBufferEnd,
        OnLoopEnd: *const fn (
            self: *IXAudio2VoiceCallback,
            pBufferContext: ?*anyopaque,
        ) callconv(.winapi) void = _onLoopEnd,
        OnVoiceError: *const fn (
            self: *IXAudio2VoiceCallback,
            pBufferContext: ?*anyopaque,
            Error: HRESULT,
        ) callconv(.winapi) void = _onVoiceError,
    };
    vtable: *const VTable,
    pub inline fn OnVoiceProcessingPassStart(self: *IXAudio2VoiceCallback, BytesRequired: u32) void {
        return self.vtable.OnVoiceProcessingPassStart(self, BytesRequired);
    }
    pub inline fn OnVoiceProcessingPassEnd(self: *IXAudio2VoiceCallback) void {
        return self.vtable.OnVoiceProcessingPassEnd(self);
    }
    pub inline fn OnStreamEnd(self: *IXAudio2VoiceCallback) void {
        return self.vtable.OnStreamEnd(self);
    }
    pub inline fn OnBufferStart(self: *IXAudio2VoiceCallback, pBufferContext: ?*anyopaque) void {
        return self.vtable.OnBufferStart(self, pBufferContext);
    }
    pub inline fn OnBufferEnd(self: *IXAudio2VoiceCallback, pBufferContext: ?*anyopaque) void {
        return self.vtable.OnBufferEnd(self, pBufferContext);
    }
    pub inline fn OnLoopEnd(self: *IXAudio2VoiceCallback, pBufferContext: ?*anyopaque) void {
        return self.vtable.OnLoopEnd(self, pBufferContext);
    }
    pub inline fn OnVoiceError(self: *IXAudio2VoiceCallback, pBufferContext: ?*anyopaque, err: HRESULT) void {
        return self.vtable.OnVoiceError(self, pBufferContext, err);
    }

    fn _onVoiceProcessingPassStart(_: *IXAudio2VoiceCallback, _: u32) callconv(.winapi) void {}
    fn _onVoiceProcessingPassEnd(_: *IXAudio2VoiceCallback) callconv(.winapi) void {}
    fn _onStreamEnd(_: *IXAudio2VoiceCallback) callconv(.winapi) void {}
    fn _onBufferStart(_: *IXAudio2VoiceCallback, _: ?*anyopaque) callconv(.winapi) void {}
    fn _onBufferEnd(_: *IXAudio2VoiceCallback, _: ?*anyopaque) callconv(.winapi) void {}
    fn _onLoopEnd(_: *IXAudio2VoiceCallback, _: ?*anyopaque) callconv(.winapi) void {}
    fn _onVoiceError(_: *IXAudio2VoiceCallback, _: ?*anyopaque, _: HRESULT) callconv(.winapi) void {}
};
