// OH_AudioRenderer 封装:按源采样率/声道/位深建流,FAST 延迟档。
#ifndef TIMBRAVA_AUDIO_OUTPUT_H
#define TIMBRAVA_AUDIO_OUTPUT_H

#include <atomic>
#include <cstdint>
#include <functional>

#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

#include "decoder.h"

namespace timbrava {

class AudioOutput {
public:
    using NeedDataFn = std::function<OH_AudioData_Callback_Result(OH_AudioRenderer *, void *userData, void *buffer,
                                                                  int32_t length)>;
    using InterruptFn = std::function<void(int forceType, int hint)>;
    using ErrorFn = std::function<void(int code)>;

    ~AudioOutput();

    bool create(const TrackInfo &info, OutputFormat fmt, NeedDataFn onData, InterruptFn onInterrupt, ErrorFn onError);
    bool createWithFormat(const TrackInfo &info, OutputFormat renderFmt, NeedDataFn onData, InterruptFn onInterrupt,
                          ErrorFn onError);
    void destroy();

    bool start();
    bool pause();
    bool stop();
    bool flush();
    bool setVolume(float vol);

private:
    static OH_AudioData_Callback_Result OnWriteData(OH_AudioRenderer *renderer, void *userData, void *buffer, int32_t length);
    static void OnInterrupt(OH_AudioRenderer *renderer, void *userData, OH_AudioInterrupt_ForceType type,
                            OH_AudioInterrupt_Hint hint);
    static void OnError(OH_AudioRenderer *renderer, void *userData, OH_AudioStream_Result error);

    OH_AudioRenderer *renderer_ = nullptr;
    OH_AudioStreamBuilder *builder_ = nullptr;
    NeedDataFn onData_;
    InterruptFn onInterrupt_;
    ErrorFn onError_;
};

} // namespace timbrava

#endif
