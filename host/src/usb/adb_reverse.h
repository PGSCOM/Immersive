#pragma once

/// USB link: a headset on a cable reaches the host through `adb reverse`,
/// which makes its own 127.0.0.1:<port> tunnel to this PC's <port>.

#include <atomic>
#include <cstdint>
#include <string>

namespace immersive {

/// Find adb and start its server; returns adb's full path, "" when there is
/// none. Looks on PATH, then where the Android SDK / platform-tools usually
/// live (a host started from the desktop may have a minimal PATH).
/// Call before opening any socket: the adb daemon it spawns inherits
/// whatever this process has open.
std::string start_adb();

/// Every 3 s until `running` goes false: `adb -s <serial> reverse tcp:<port>
/// tcp:<port>` on each authorised device that lacks it, so a replug or a
/// headset reboot re-arms it. A rule already there (from an earlier run or
/// the user's own adb) is left alone. Logs only changes: a headset ready,
/// one waiting for the USB debugging prompt, one unplugged. Blocks; run it
/// on its own thread.
void keep_adb_reverse(const std::string& adb, uint16_t port, const std::atomic<bool>& running);

}  // namespace immersive
