#ifndef PIPPINVR_NDK_HANDLES_H
#define PIPPINVR_NDK_HANDLES_H

#include <memory>

#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>

namespace pippinvr {

struct ImageReaderDeleter {
    void operator()(AImageReader* p) const noexcept {
        if (p != nullptr) AImageReader_delete(p);
    }
};

struct ImageDeleter {
    void operator()(AImage* p) const noexcept {
        if (p != nullptr) AImage_delete(p);
    }
};

struct MediaCodecDeleter {
    void operator()(AMediaCodec* p) const noexcept {
        if (p == nullptr) return;
        AMediaCodec_stop(p);
        AMediaCodec_delete(p);
    }
};

struct MediaFormatDeleter {
    void operator()(AMediaFormat* p) const noexcept {
        if (p != nullptr) AMediaFormat_delete(p);
    }
};

using ImageReaderPtr = std::unique_ptr<AImageReader, ImageReaderDeleter>;
using ImagePtr       = std::unique_ptr<AImage, ImageDeleter>;
using MediaCodecPtr  = std::unique_ptr<AMediaCodec, MediaCodecDeleter>;
using MediaFormatPtr = std::unique_ptr<AMediaFormat, MediaFormatDeleter>;

}

#endif  // PIPPINVR_NDK_HANDLES_H
