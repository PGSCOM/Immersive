#pragma once

/// Media Foundation hardware video encoder.
///
/// Uses Windows Media Foundation Transform (MFT) to perform H.264 encoding
/// on the GPU.  Works with NVIDIA (NVENC), AMD (AMF), and Intel (QSV) GPUs
/// through the unified OS MFT infrastructure available on Windows 8+.
///
/// If no hardware MFT encoder is available the implementation falls back to
/// the software MFT H.264 encoder shipped with Windows.
///
/// Required headers: <mfapi.h>, <mftransform.h>, <mfidl.h>,
///                   <codecapi.h>, <mferror.h>
///
/// Required libraries: mf.lib, mfuuid.lib, mfplat.lib, strmiids.lib

#include "encoder/encoder.h"

namespace immersive {

/// Create a Media Foundation hardware (or software-fallback) video encoder.
/// The codec is taken from EncoderConfig::codec at initialize() time
/// (H.264, HEVC or AV1). Returns nullptr if MF is not available.
std::unique_ptr<IVideoEncoder> create_mf_encoder();

/// Returns true if an MFT encoder for the given codec exists on this machine
/// (hardware for HEVC/AV1; hardware or software for H.264).
bool mf_encoder_available(VideoCodec codec);

/// Returns true if a hardware MFT H.264 encoder was found on this machine.
/// Useful for detect_best_encoder().
bool mf_hardware_encoder_available();

}  // namespace immersive
