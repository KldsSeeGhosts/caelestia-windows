// Focused checks for the WASAPI mix-format decisions that feed the visualiser.
// The parser and downmix are pure so these run offscreen without an audio
// endpoint; event-driven capture itself needs a live output device.

#include <audioclient.h>
#include <mmreg.h>
#include <windows.h>

#include <QtTest/QtTest>
#include <cmath>
#include <cstdint>
#include <vector>

#include "wasapiformat.hpp"

namespace {

using caelestia::shell::windows::audio::downmixToMono;
using caelestia::shell::windows::audio::MixFormat;
using caelestia::shell::windows::audio::mixFormatFrom;

constexpr GUID kSubtypeFloat = { 0x00000003, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
constexpr GUID kSubtypePcm = { 0x00000001, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

WAVEFORMATEX format(WORD tag, WORD channels, WORD bits) {
    WAVEFORMATEX value{};
    value.wFormatTag = tag;
    value.nChannels = channels;
    value.nSamplesPerSec = 48000;
    value.wBitsPerSample = bits;
    value.nBlockAlign = static_cast<WORD>(channels * (bits / 8));
    value.nAvgBytesPerSec = value.nSamplesPerSec * value.nBlockAlign;
    return value;
}

WAVEFORMATEXTENSIBLE extensible(WORD bits, WORD channels, const GUID& subtype, WORD cbSize = 22) {
    WAVEFORMATEXTENSIBLE value{};
    value.Format = format(WAVE_FORMAT_EXTENSIBLE, channels, bits);
    value.Format.cbSize = cbSize;
    value.Samples.wValidBitsPerSample = bits;
    value.dwChannelMask = channels == 2 ? 0x3 : 0; // SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT
    value.SubFormat = subtype;
    return value;
}

bool almostEqual(float actual, float expected) {
    return std::fabs(actual - expected) < 1e-6f;
}

} // namespace

class WasapiFormatTest : public QObject {
    Q_OBJECT

private slots:
    void float32();
    void pcm16();
    void pcm32();
    void extensibleFloat32();
    void extensiblePcm16();
    void extensiblePcm32();
    void rejectsEightBit();
    void rejectsPackedTwentyFourBit();
    void rejectsBlockAlignMismatch();
    void rejectsUnknownSubtype();
    void rejectsTruncatedExtensible();
    void rejectsZeroChannels();
    void downmixFloat();
    void downmixPcm16();
    void downmixPcm32();
    void downmixAveragesChannels();
    void eventDrivenSupportStartsAt1703();
    void loopbackFlagsIncludeEventCallback();
};

void WasapiFormatTest::float32() {
    const auto value = format(WAVE_FORMAT_IEEE_FLOAT, 2, 32);
    QCOMPARE(mixFormatFrom(&value), MixFormat::Float32);
}

void WasapiFormatTest::pcm16() {
    const auto value = format(WAVE_FORMAT_PCM, 2, 16);
    QCOMPARE(mixFormatFrom(&value), MixFormat::Pcm16);
}

void WasapiFormatTest::pcm32() {
    const auto value = format(WAVE_FORMAT_PCM, 2, 32);
    QCOMPARE(mixFormatFrom(&value), MixFormat::Pcm32);
}

void WasapiFormatTest::extensibleFloat32() {
    const auto value = extensible(32, 2, kSubtypeFloat);
    QCOMPARE(mixFormatFrom(&value.Format), MixFormat::Float32);
}

void WasapiFormatTest::extensiblePcm16() {
    const auto value = extensible(16, 2, kSubtypePcm);
    QCOMPARE(mixFormatFrom(&value.Format), MixFormat::Pcm16);
}

void WasapiFormatTest::extensiblePcm32() {
    const auto value = extensible(32, 2, kSubtypePcm);
    QCOMPARE(mixFormatFrom(&value.Format), MixFormat::Pcm32);
}

void WasapiFormatTest::rejectsEightBit() {
    const auto value = format(WAVE_FORMAT_PCM, 2, 8);
    QCOMPARE(mixFormatFrom(&value), MixFormat::Unsupported);
}

void WasapiFormatTest::rejectsPackedTwentyFourBit() {
    auto value = format(WAVE_FORMAT_PCM, 2, 24);
    QCOMPARE(mixFormatFrom(&value), MixFormat::Unsupported);

    auto packed = extensible(24, 2, kSubtypePcm);
    QCOMPARE(mixFormatFrom(&packed.Format), MixFormat::Unsupported);
}

void WasapiFormatTest::rejectsBlockAlignMismatch() {
    auto value = format(WAVE_FORMAT_PCM, 2, 16);
    value.nBlockAlign = 3;
    QCOMPARE(mixFormatFrom(&value), MixFormat::Unsupported);
}

void WasapiFormatTest::rejectsUnknownSubtype() {
    constexpr GUID kSubtypeUnknown = { 0x00000092, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
    const auto value = extensible(32, 2, kSubtypeUnknown);
    QCOMPARE(mixFormatFrom(&value.Format), MixFormat::Unsupported);
}

void WasapiFormatTest::rejectsTruncatedExtensible() {
    const auto value = extensible(32, 2, kSubtypeFloat, 0);
    QCOMPARE(mixFormatFrom(&value.Format), MixFormat::Unsupported);
}

void WasapiFormatTest::rejectsZeroChannels() {
    auto value = format(WAVE_FORMAT_IEEE_FLOAT, 0, 32);
    value.nBlockAlign = 0;
    QCOMPARE(mixFormatFrom(&value), MixFormat::Unsupported);
    QCOMPARE(mixFormatFrom(nullptr), MixFormat::Unsupported);
}

void WasapiFormatTest::downmixFloat() {
    const std::vector<float> input{ 1.0f, 0.0f, -1.0f, 1.0f };
    std::vector<float> output(2);
    downmixToMono(MixFormat::Float32, reinterpret_cast<const BYTE*>(input.data()), 2, 2, output.data());
    QVERIFY(almostEqual(output[0], 0.5f));
    QVERIFY(almostEqual(output[1], 0.0f));
}

void WasapiFormatTest::downmixPcm16() {
    const std::vector<std::int16_t> input{ 16384, -16384 };
    std::vector<float> output(2);
    downmixToMono(MixFormat::Pcm16, reinterpret_cast<const BYTE*>(input.data()), 2, 1, output.data());
    QVERIFY(almostEqual(output[0], 0.5f));
    QVERIFY(almostEqual(output[1], -0.5f));
}

void WasapiFormatTest::downmixPcm32() {
    const std::vector<std::int32_t> input{ 1073741824, -1073741824 };
    std::vector<float> output(2);
    downmixToMono(MixFormat::Pcm32, reinterpret_cast<const BYTE*>(input.data()), 2, 1, output.data());
    QVERIFY(almostEqual(output[0], 0.5f));
    QVERIFY(almostEqual(output[1], -0.5f));
}

void WasapiFormatTest::downmixAveragesChannels() {
    const std::vector<float> input{ 0.3f, 0.6f, 0.9f, 1.0f, 1.0f, 1.0f };
    std::vector<float> output(2);
    downmixToMono(MixFormat::Float32, reinterpret_cast<const BYTE*>(input.data()), 2, 3, output.data());
    QVERIFY(almostEqual(output[0], 0.6f));
    QVERIFY(almostEqual(output[1], 1.0f));
}

void WasapiFormatTest::eventDrivenSupportStartsAt1703() {
    using caelestia::shell::windows::audio::eventDrivenLoopbackSupported;
    QVERIFY(!eventDrivenLoopbackSupported(15062));
    QVERIFY(eventDrivenLoopbackSupported(15063));
    QVERIFY(eventDrivenLoopbackSupported(22631));
    // An unknown build means ntdll did not answer; do not disable capture.
    QVERIFY(eventDrivenLoopbackSupported(0));
}

void WasapiFormatTest::loopbackFlagsIncludeEventCallback() {
    using caelestia::shell::windows::audio::kLoopbackFlags;
    QVERIFY((kLoopbackFlags & AUDCLNT_STREAMFLAGS_LOOPBACK) != 0);
    QVERIFY((kLoopbackFlags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK) != 0);
}

QTEST_GUILESS_MAIN(WasapiFormatTest)

#include "wasapiformat_test.moc"
