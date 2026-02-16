/// UDP video stream helpers.
///
/// Utility functions for packetizing and sending video frames over UDP.

#include "network/server.h"
#include <cstring>
#include <vector>

namespace immersive {
namespace udp {

std::vector<std::vector<uint8_t>> packetize_frame(
        uint8_t monitor_id,
        uint32_t frame_number,
        const uint8_t* encoded_data,
        uint32_t encoded_size) {
    uint16_t chunk_count = protocol::compute_chunk_count(encoded_size);
    std::vector<std::vector<uint8_t>> packets;
    packets.reserve(chunk_count);

    for (uint16_t i = 0; i < chunk_count; ++i) {
        uint32_t offset = i * protocol::MAX_UDP_PAYLOAD;
        uint32_t chunk_size = std::min(
            static_cast<uint32_t>(protocol::MAX_UDP_PAYLOAD),
            encoded_size - offset);

        std::vector<uint8_t> packet(sizeof(protocol::VideoPacketHeader) + chunk_size);

        protocol::VideoPacketHeader header;
        header.monitor_id = monitor_id;
        header.frame_number = frame_number;
        header.chunk_index = i;
        header.chunk_count = chunk_count;

        std::memcpy(packet.data(), &header, sizeof(header));
        std::memcpy(packet.data() + sizeof(header), encoded_data + offset, chunk_size);

        packets.push_back(std::move(packet));
    }

    return packets;
}

}  // namespace udp
}  // namespace immersive
