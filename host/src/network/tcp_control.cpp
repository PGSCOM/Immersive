/// TCP control channel helpers.
///
/// Utility functions for building and parsing control messages.

#include "network/server.h"
#include <cstring>
#include <vector>

namespace immersive {
namespace tcp {

std::vector<uint8_t> build_control_message(protocol::MessageType type,
                                           const void* payload,
                                           uint32_t payload_size) {
    std::vector<uint8_t> buffer(sizeof(protocol::ControlHeader) + payload_size);

    protocol::ControlHeader header;
    header.type = static_cast<uint8_t>(type);
    header.length = payload_size;

    std::memcpy(buffer.data(), &header, sizeof(header));
    if (payload && payload_size > 0) {
        std::memcpy(buffer.data() + sizeof(header), payload, payload_size);
    }

    return buffer;
}

bool parse_control_header(const uint8_t* data, size_t size,
                          protocol::ControlHeader& out_header) {
    if (size < sizeof(protocol::ControlHeader)) return false;
    std::memcpy(&out_header, data, sizeof(out_header));
    return true;
}

}  // namespace tcp
}  // namespace immersive
