// nx-accel: screen orientation for the Linux desktop, from the phone's accelerometer.
//
// The accelerometer sits behind Qualcomm's sensor hub and is only reachable through Android's
// sensors HAL (android.hardware.sensors.ISensors/default, AIDL V2). On a Linux boot the Android
// framework never starts, so nobody else has initialized the HAL and this program can: it opens
// the HAL's event queue, streams the non-wakeup accelerometer at 10 Hz and writes the orientation
// ("normal", "left", "right" or "inverted", in kscreen's terms) to the file given as argument
// whenever it changes. Debian's nx-orientation rotates the screen from that file.
// NEVER run this on an Android boot: the HAL accepts one client, and that is the system server.
//   nx-accel /data/nx-linux/orientation [-v]
#include <aidl/android/hardware/sensors/BnSensorsCallback.h>
#include <aidl/android/hardware/sensors/ISensors.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fmq/AidlMessageQueue.h>
#include <fmq/EventFlag.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using aidl::android::hardware::sensors::BnSensorsCallback;
using aidl::android::hardware::sensors::Event;
using aidl::android::hardware::sensors::ISensors;
using aidl::android::hardware::sensors::SensorInfo;
using aidl::android::hardware::sensors::SensorType;
using android::AidlMessageQueue;
using android::hardware::EventFlag;

using EventQueue = AidlMessageQueue<Event, SynchronizedReadWrite>;
using WakeQueue = AidlMessageQueue<int32_t, SynchronizedReadWrite>;

namespace {

class Callback : public BnSensorsCallback {
  public:
    ndk::ScopedAStatus onDynamicSensorsConnected(const std::vector<SensorInfo>&) override {
        return ndk::ScopedAStatus::ok();
    }
    ndk::ScopedAStatus onDynamicSensorsDisconnected(const std::vector<int32_t>&) override {
        return ndk::ScopedAStatus::ok();
    }
};

// Orientation from gravity (m/s^2, Android's device axes: x right, y up the screen, z out of it).
// Only a clear tilt changes it (the dominant axis must carry most of gravity), and a phone lying
// flat keeps the last orientation.
const char* orientation(float x, float y, float z, const char* last) {
    const float g = std::sqrt(x * x + y * y + z * z);
    if (g < 4.0f || std::fabs(z) > 0.8f * g) return last;  // flat or in free fall
    if (std::fabs(y) > 1.6f * std::fabs(x)) return y > 0 ? "normal" : "inverted";
    // (kscreen turns the picture the other way round from the device's x axis: checked on the phone)
    if (std::fabs(x) > 1.6f * std::fabs(y)) return x > 0 ? "right" : "left";
    return last;  // around 45 degrees: keep what we have
}

bool writeFile(const std::string& path, const char* value) {
    const std::string tmp = path + ".new";
    FILE* f = std::fopen(tmp.c_str(), "w");
    if (!f) return false;
    std::fprintf(f, "%s\n", value);
    std::fclose(f);
    return std::rename(tmp.c_str(), path.c_str()) == 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: nx-accel <orientation file> [-v]\n");
        return 2;
    }
    const std::string out = argv[1];
    const bool verbose = argc > 2 && std::strcmp(argv[2], "-v") == 0;

    const std::string name = std::string(ISensors::descriptor) + "/default";
    auto sensors = ISensors::fromBinder(ndk::SpAIBinder(AServiceManager_waitForService(name.c_str())));
    if (!sensors) {
        std::fprintf(stderr, "nx-accel: no %s\n", name.c_str());
        return 1;
    }
    ABinderProcess_startThreadPool();

    EventQueue events(256, true);
    WakeQueue wakes(64, true);
    auto st = sensors->initialize(events.dupeDesc(), wakes.dupeDesc(), ndk::SharedRefBase::make<Callback>());
    if (!st.isOk()) {
        std::fprintf(stderr, "nx-accel: initialize failed: %s\n", st.getDescription().c_str());
        return 1;
    }

    std::vector<SensorInfo> list;
    sensors->getSensorsList(&list);
    int32_t handle = -1;
    for (const auto& s : list) {
        if (s.type == SensorType::ACCELEROMETER && !(s.flags & SensorInfo::SENSOR_FLAG_BITS_WAKE_UP)) {
            handle = s.sensorHandle;
            std::fprintf(stderr, "nx-accel: using %s (%s), handle %d\n", s.name.c_str(), s.vendor.c_str(), handle);
            break;
        }
    }
    if (handle < 0) {
        std::fprintf(stderr, "nx-accel: no accelerometer among %zu sensors\n", list.size());
        return 1;
    }
    sensors->batch(handle, 100'000'000 /* 100 ms */, 0);
    sensors->activate(handle, true);

    EventFlag* flag = nullptr;
    if (EventFlag::createEventFlag(events.getEventFlagWord(), &flag) != android::OK) {
        std::fprintf(stderr, "nx-accel: no event flag\n");
        return 1;
    }

    const char* last = "normal";
    writeFile(out, last);
    std::vector<Event> buf(64);
    for (;;) {
        uint32_t bits = 0;
        flag->wait(static_cast<uint32_t>(ISensors::EVENT_QUEUE_FLAG_BITS_READ_AND_PROCESS), &bits);
        size_t n = std::min(events.availableToRead(), buf.size());
        if (n == 0 || !events.read(buf.data(), n)) continue;
        flag->wake(static_cast<uint32_t>(ISensors::EVENT_QUEUE_FLAG_BITS_EVENTS_READ));
        for (size_t i = 0; i < n; i++) {
            const Event& e = buf[i];
            if (e.sensorHandle != handle || e.payload.getTag() != Event::EventPayload::vec3) continue;
            const auto& v = e.payload.get<Event::EventPayload::vec3>();
            if (verbose) std::fprintf(stderr, "%7.2f %7.2f %7.2f\n", v.x, v.y, v.z);
            const char* now = orientation(v.x, v.y, v.z, last);
            if (std::strcmp(now, last) != 0) {
                last = now;
                if (!writeFile(out, last)) std::fprintf(stderr, "nx-accel: cannot write %s\n", out.c_str());
                if (verbose) std::fprintf(stderr, "-> %s\n", last);
            }
        }
    }
}
