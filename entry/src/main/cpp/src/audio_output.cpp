#include "audio_output.h"

#define LOG_TAG "[TimbravaNative][Output]"
#include <hilog/log.h>

namespace timbrava {

AudioOutput::~AudioOutput() { destroy(); }

OH_AudioData_Callback_Result AudioOutput::OnWriteData(OH_AudioRenderer *renderer, void *userData, void *buffer,
                                                      int32_t length) {
    (void)renderer;
    AudioOutput *self = static_cast<AudioOutput *>(userData);
    if (self == nullptr || !self->onData_) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    return self->onData_(renderer, userData, buffer, length);
}

void AudioOutput::OnInterrupt(OH_AudioRenderer *renderer, void *userData, OH_AudioInterrupt_ForceType type,
                              OH_AudioInterrupt_Hint hint) {
    (void)renderer;
    AudioOutput *self = static_cast<AudioOutput *>(userData);
    if (self != nullptr && self->onInterrupt_) {
        self->onInterrupt_(static_cast<int>(type), static_cast<int>(hint));
    }
}

void AudioOutput::OnError(OH_AudioRenderer *renderer, void *userData, OH_AudioStream_Result error) {
    (void)renderer;
    AudioOutput *self = static_cast<AudioOutput *>(userData);
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "renderer error=%{public}d", static_cast<int>(error));
    if (self != nullptr && self->onError_) {
        self->onError_(static_cast<int>(error));
    }
}

bool AudioOutput::create(const TrackInfo &info, OutputFormat fmt, NeedDataFn onData, InterruptFn onInterrupt,
                         ErrorFn onError) {
    return createWithFormat(info, fmt, std::move(onData), std::move(onInterrupt), std::move(onError));
}

bool AudioOutput::createWithFormat(const TrackInfo &info, OutputFormat fmt, NeedDataFn onData, InterruptFn onInterrupt,
                                   ErrorFn onError) {
    onData_ = std::move(onData);
    onInterrupt_ = std::move(onInterrupt);
    onError_ = std::move(onError);

    OH_AudioStream_Result r = OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER);
    if (r != AUDIOSTREAM_SUCCESS) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "builder create fail %{public}d", static_cast<int>(r));
        return false;
    }
    OH_AudioStream_SampleFormat sf = AUDIOSTREAM_SAMPLE_S16LE;
    switch (fmt) {
        case OutputFormat::U8:
            sf = AUDIOSTREAM_SAMPLE_U8;
            break;
        case OutputFormat::S16LE:
            sf = AUDIOSTREAM_SAMPLE_S16LE;
            break;
        case OutputFormat::S32LE:
            sf = AUDIOSTREAM_SAMPLE_S32LE;
            break;
        case OutputFormat::F32LE:
            sf = AUDIOSTREAM_SAMPLE_F32LE;
            break;
    }
    OH_AudioStreamBuilder_SetSamplingRate(builder_, info.sampleRate);
    OH_AudioStreamBuilder_SetChannelCount(builder_, info.channels);
    OH_AudioStreamBuilder_SetSampleFormat(builder_, sf);
    OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_, OnWriteData, this);
    OH_AudioStreamBuilder_SetRendererInterruptCallback(builder_, OnInterrupt, this);
    OH_AudioStreamBuilder_SetRendererErrorCallback(builder_, OnError, this);
    r = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (r != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "generate renderer fail %{public}d rate=%{public}d ch=%{public}d "
                                                     "fmt=%{public}d",
                     static_cast<int>(r), info.sampleRate, info.channels, static_cast<int>(sf));
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "renderer ready rate=%{public}d ch=%{public}d fmt=%{public}d",
                 info.sampleRate, info.channels, static_cast<int>(sf));
    return true;
}

void AudioOutput::destroy() {
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Stop(renderer_);
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }
    if (builder_ != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }
}

bool AudioOutput::start() {
    return renderer_ != nullptr && OH_AudioRenderer_Start(renderer_) == AUDIOSTREAM_SUCCESS;
}

bool AudioOutput::pause() {
    return renderer_ != nullptr && OH_AudioRenderer_Pause(renderer_) == AUDIOSTREAM_SUCCESS;
}

bool AudioOutput::stop() {
    return renderer_ != nullptr && OH_AudioRenderer_Stop(renderer_) == AUDIOSTREAM_SUCCESS;
}

bool AudioOutput::flush() {
    return renderer_ != nullptr && OH_AudioRenderer_Flush(renderer_) == AUDIOSTREAM_SUCCESS;
}

bool AudioOutput::setVolume(float vol) {
    return renderer_ != nullptr && OH_AudioRenderer_SetVolume(renderer_, vol) == AUDIOSTREAM_SUCCESS;
}

} // namespace timbrava
