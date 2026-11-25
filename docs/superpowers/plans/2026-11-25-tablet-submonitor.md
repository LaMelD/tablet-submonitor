# 갤럭시탭 USB 서브모니터 (1차, macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 이 맥북에 가상 디스플레이를 만들고, 그 화면을 USB로 갤럭시탭 S8 Ultra에 저지연으로 띄운다. 커서는 탭이 직접 그린다.

**Architecture:** Swift 호스트가 `CGVirtualDisplay`로 가상 디스플레이를 만들고, FFmpeg를 하위 프로세스로 실행한다. FFmpeg는 커서를 뺀 화면을 HEVC로 압축해 FLV로 TCP 28100에 내보낸다. 호스트는 커서 좌표·모양을 TCP 28101로 보낸다. 두 연결은 `adb reverse`로 USB를 거쳐 탭의 Kotlin 앱에 닿는다. 앱은 MediaCodec으로 디코딩해 즉시 표시하고, 그 위에 커서를 그린다.

**Tech Stack:** Swift 6.4 (SwiftPM, XCTest, Network.framework, AppKit), FFmpeg 9 (`avfoundation`, `hevc_videotoolbox`, `flv`), adb, Kotlin + Android SDK 36 (MediaCodec, JUnit 4)

**Spec:** `docs/superpowers/specs/2026-11-25-tablet-submonitor-design.md`

## Global Constraints

- 대상 기기: 이 맥북(macOS 27, Apple Silicon)과 갤럭시탭 S8 Ultra(2960×1848, 120Hz)
- 가상 디스플레이: 2960×1848 px, HiDPI(1480×924 pt), 120Hz. 이름 `Submonitor`
- 전송은 USB `adb reverse`만 쓴다. 영상 TCP **28100**, 커서 TCP **28101**. 호스트 소켓은 `127.0.0.1`에만 바인드한다.
- 모든 TCP 소켓에서 Nagle 알고리즘을 끈다(호스트, FFmpeg `tcp_nodelay=1`, Android `tcpNoDelay = true`).
- 영상: `hevc_videotoolbox`, B-프레임 없음, 컨테이너 FLV(Enhanced FLV, fourcc `hvc1`)
- 기본값: fps 120, 비트레이트 `40M`. 60Hz 대안은 `--fps 60`
- 호스트: SwiftPM, swift-tools-version 6.0, Swift 5 언어 모드, 외부 Swift 패키지 의존성 없음
- 호스트는 `ffmpeg`와 `adb`를 `/usr/bin/env`로 실행한다(PATH에서 찾음).
- Android: 패키지 `dev.submonitor`, Kotlin, minSdk 30, compileSdk/targetSdk 36
  - 라이브러리 의존성 없음(AndroidX 포함). 테스트에만 JUnit 4를 쓴다.
- 탭에서 호스트로 가는 입력(터치·S Pen)은 없다.
- 사용자에게 보이는 호스트 메시지는 한국어로 쓴다.

## Review Focus

1. 탭 앱이 백그라운드에 갔다 돌아오거나 화면이 꺼졌다 켜짐 → 몇 초 안에 자동으로 다시 화면이 나온다. (Task 4 기기 확인)
2. 호스트 실행 중 USB를 뺐다 다시 꽂음 → 호스트는 죽지 않고, 다시 꽂으면 자동으로 화면이 복구된다. (Task 6 기기 확인)
3. 커서가 메인 화면과 탭 화면 경계(가장자리 포함)를 넘나듦 → 커서가 탭 밖에 있으면 탭에서 사라진다. (Task 5 단위 테스트 + 기기 확인)
4. 화면 기록 권한이 없어 FFmpeg가 바로 죽음 → 재시작을 무한 반복하지 않고 권한 안내와 FFmpeg 오류를 출력한 뒤 종료한다. (Task 2 단위 테스트)
5. 이전 실행이 비정상 종료되어 FFmpeg가 포트 28100을 잡고 남아 있음 → 새 실행이 충돌 없이 시작된다. (Task 6 확인)

---

### Task 1: 가상 디스플레이 (Swift 패키지 골격 포함)

가장 위험한 가정(macOS 27에서 비공개 API로 HiDPI 120Hz 디스플레이가 만들어지는가)을 먼저 확인한다.
런타임 확인 결과: `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` 클래스가 존재하고, CoreGraphics에 직접 링크된다.

**Files:**
- Create: `.gitignore` (`host/.build/`, `android/.gradle/`, `android/build/`, `android/app/build/`, `android/local.properties`)
- Create: `host/Package.swift`
- Create: `host/Sources/CGVirtualDisplayPrivate/include/CGVirtualDisplayPrivate.h`
- Create: `host/Sources/CGVirtualDisplayPrivate/CGVirtualDisplayPrivate.m` (`#import "CGVirtualDisplayPrivate.h"` 한 줄. SwiftPM이 소스 파일을 요구해서 둔다)
- Create: `host/Sources/submonitor/VirtualDisplay.swift`
- Create: `host/Sources/submonitor/main.swift` (임시: 디스플레이를 만들고 정보를 출력한 뒤 Ctrl-C까지 대기)

**Interfaces:**
- Produces: `final class VirtualDisplay { init(name: String, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) throws; let displayID: CGDirectDisplayID }`
  - 객체가 해제되면 디스플레이가 사라진다.
  - 생성 후 HiDPI 모드(논리 = 픽셀/2)가 적용된 상태여야 한다.

- [ ] **Step 1: `Package.swift` 작성**

`platforms: [.macOS(.v14)]`, `swiftLanguageModes: [.v5]`로 둔다. 타깃은 둘이다.
- `CGVirtualDisplayPrivate`: `linkerSettings: [.linkedFramework("CoreGraphics")]`
- `submonitor`: executableTarget, 의존성 `CGVirtualDisplayPrivate`

`SubmonitorCore`와 테스트 타깃은 Task 2에서 추가한다.

- [ ] **Step 2: 비공개 API 헤더 작성**

런타임 메서드 목록에서 확인한 선언만 쓴다:

```objc
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end
NS_ASSUME_NONNULL_END
```

- [ ] **Step 3: `VirtualDisplay` 구현**

descriptor 값:
- `maxPixelsWide/High` = 2960/1848
- `sizeInMillimeters` = 315×197 (14.6인치 16:10)
- `hiDPI = 1`
- 모드 두 개: 2960×1848@120, 1480×924@120

`applySettings` 후 다음 순서로 HiDPI 모드를 고른다.
1. `CGDisplayCopyAllDisplayModes`에 `kCGDisplayShowDuplicateLowResolutionModes: true`를 줘서 모드 목록을 받는다.
2. `width == 1480 && pixelWidth == 2960`인 모드를 `CGDisplaySetDisplayMode`로 적용한다.
3. 그런 모드가 없으면 실패 이유를 담은 에러를 던진다.

- [ ] **Step 4: 임시 `main.swift`**

1. `VirtualDisplay(name: "Submonitor", pixelWidth: 2960, pixelHeight: 1848, refreshRate: 120)`을 만든다.
2. `CGDisplayCopyDisplayMode`의 `width×height`, `pixelWidth×pixelHeight`, `refreshRate`를 출력한다.
3. `dispatchMain()`으로 대기한다.

- [ ] **Step 5: 실행해 확인**

Run: `swift run --package-path host submonitor`
Expected:
- `1480x924 pt / 2960x1848 px @120Hz`에 해당하는 출력이 나온다.
- 시스템 설정 > 디스플레이에 `Submonitor`가 보인다.
- Ctrl-C 후 디스플레이가 사라진다.

**실패 시:** 120Hz가 거부되면 60으로 다시 확인하고 결과를 기록한다. 디스플레이 자체가 안 만들어지면 여기서 멈추고 사용자에게 보고한다. 설계 전제가 깨진 것이다.

- [ ] **Step 6: Commit**

```bash
git add .gitignore host
git commit -m "feat(host): CGVirtualDisplay로 HiDPI 가상 디스플레이 생성"
```

---

### Task 2: 캡처·인코딩 파이프라인

두 번째 위험(구형 `avfoundation` API로 가상 디스플레이를 캡처할 수 있는가, 몇 fps가 나오는가)을 확인한다.

**Files:**
- Modify: `host/Package.swift` (`SubmonitorCore` 라이브러리 타깃, `SubmonitorCoreTests` 테스트 타깃 추가, `submonitor`가 `SubmonitorCore`에 의존)
- Create: `host/Sources/SubmonitorCore/Capture.swift`
- Create: `host/Tests/SubmonitorCoreTests/CaptureTests.swift`
- Create: `host/Sources/submonitor/FFmpegRunner.swift`
- Modify: `host/Sources/submonitor/main.swift`

**Interfaces:**
- Consumes: `VirtualDisplay` (Task 1)
- Produces (`SubmonitorCore`, 모두 `public`):
  - `func screenDeviceName(for displayID: UInt32, activeDisplays: [UInt32]) -> String?`
    - `activeDisplays`에서의 순번 N으로 `"Capture screen N"`을 만든다. FFmpeg `avfoundation`이 `CGGetActiveDisplayList` 순서로 화면 번호를 매기기 때문이다.
  - `func ffmpegArguments(screenDevice: String, fps: Int, bitrate: String, port: UInt16) -> [String]`
  - `struct RestartPolicy { init(minHealthyRun: TimeInterval = 2, maxFastFailures: Int = 3); mutating func onExit(runDuration: TimeInterval) -> RestartDecision }`
  - `enum RestartDecision: Equatable { case restart, giveUp }`
- Produces (`submonitor`): `final class FFmpegRunner { init(arguments: [String], onGiveUp: @escaping (_ stderrTail: String) -> Void); func start(); func stop() }`

- [ ] **Step 1: 실패하는 테스트 작성** (`CaptureTests.swift`)

```swift
func testScreenDeviceNameUsesActiveDisplayIndex() {
    XCTAssertEqual(screenDeviceName(for: 7, activeDisplays: [1, 7]), "Capture screen 1")
    XCTAssertNil(screenDeviceName(for: 9, activeDisplays: [1, 7]))
}

func testFFmpegArgumentsPinLatencyCriticalOptions() {
    let a = ffmpegArguments(screenDevice: "Capture screen 1", fps: 120, bitrate: "40M", port: 28100)
    // assertPair: a 안 어딘가에 [flag, value]가 연속으로 있는지 확인하는 테스트 헬퍼 ("-f"는 두 번 나온다)
    assertPair(a, "-f", "avfoundation"); assertPair(a, "-capture_cursor", "0")
    assertPair(a, "-framerate", "120"); assertPair(a, "-i", "Capture screen 1:none")
    assertPair(a, "-c:v", "hevc_videotoolbox"); assertPair(a, "-realtime", "1"); assertPair(a, "-bf", "0")
    assertPair(a, "-b:v", "40M"); assertPair(a, "-flush_packets", "1"); assertPair(a, "-f", "flv")
    XCTAssertEqual(a.last, "tcp://127.0.0.1:28100?listen=1&tcp_nodelay=1")
}

// Review Focus 4: 권한이 없어 FFmpeg가 바로 죽으면 무한 재시작하지 않는다
func testRestartPolicyGivesUpAfterThreeFastFailures() {
    var p = RestartPolicy()
    XCTAssertEqual(p.onExit(runDuration: 0.5), .restart)
    XCTAssertEqual(p.onExit(runDuration: 0.5), .restart)
    XCTAssertEqual(p.onExit(runDuration: 0.5), .giveUp)
}

// 탭 앱이 연결을 끊으면 FFmpeg가 종료된다. 오래 돈 뒤의 종료는 정상 재시작이다
func testRestartPolicyResetsAfterHealthyRun() {
    var p = RestartPolicy()
    _ = p.onExit(runDuration: 0.5); _ = p.onExit(runDuration: 0.5)
    XCTAssertEqual(p.onExit(runDuration: 30), .restart)
    XCTAssertEqual(p.onExit(runDuration: 0.5), .restart)
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --package-path host`
Expected: 컴파일 실패(`screenDeviceName` 등 미정의)

- [ ] **Step 3: `Capture.swift` 구현**

나머지 FFmpeg 튜닝 값은 구현자 재량이다(예: `-pixel_format nv12`로 변환 생략, `-g`는 fps×10, `-prio_speed 1`).

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --package-path host`
Expected: 4개 PASS

- [ ] **Step 5: `FFmpegRunner` 구현**

동작:
- `/usr/bin/env ffmpeg <args>`를 `Process`로 실행하고, stderr 마지막 20줄을 보관한다.
- 종료되면(직접 `stop()`한 경우 제외) `RestartPolicy.onExit`를 묻는다.
  - `.restart`면 300ms 뒤 다시 실행한다.
  - `.giveUp`이면 `onGiveUp(stderrTail)`을 부른다.

- [ ] **Step 6: `main.swift` 연결**

1. 디스플레이를 만든 뒤 `CGGetActiveDisplayList`에 나타날 때까지 100ms 간격으로 최대 3초 기다린다.
2. `screenDeviceName`으로 장치 이름을 구하고 `FFmpegRunner`를 시작한다.
3. `onGiveUp`에서는 stderr 내용과 다음 안내를 출력하고 `exit(1)`한다: `화면 기록 권한을 확인하세요: 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 이 터미널 앱을 허용`
4. SIGINT/SIGTERM이 오면 `DispatchSource.makeSignalSource`로 받아 `runner.stop()` 후 `exit(0)`한다.

- [ ] **Step 7: 실제 캡처 확인 (위험 2)**

Run (터미널 1): `swift run --package-path host submonitor`

Run (터미널 2): `ffplay -fflags nobuffer -flags low_delay -framedrop tcp://127.0.0.1:28100`
- 가상 디스플레이 내용이 메인 화면의 창으로 보인다.
- 창 하나를 마우스로 가상 디스플레이 쪽에 끌어다 놓으면 ffplay 창에 나타난다.
- 커서는 영상에 없어야 한다.

ffplay를 닫은 뒤 Run (터미널 2): `ffmpeg -hide_banner -i tcp://127.0.0.1:28100 -t 10 -f null - 2>&1 | grep -E "Stream|fps="`
Expected:
- `hevc`, `2960x1848`이 보인다.
- 가상 디스플레이에서 화면이 계속 바뀌는 동안(예: 영상 재생) fps가 110 이상이다.
- 연결을 끊을 때마다 호스트가 FFmpeg를 다시 띄운다(다음 연결이 된다).

**실패 시:**
- fps가 120에 못 미치면 `--fps 60` 값(Task 6 전까지는 상수 변경)으로 다시 재고 결과를 기록한다.
- 캡처 자체가 안 되면 멈추고 사용자에게 보고한다. 설계상 C안(ScreenCaptureKit)으로 가는 조건이다.

- [ ] **Step 8: Commit**

```bash
git add host
git commit -m "feat(host): FFmpeg로 가상 디스플레이를 HEVC/FLV 스트림으로 송출"
```

---

### Task 3: Android 프로젝트 골격과 FLV 파서

**Files:**
- Create: `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/app/build.gradle.kts`, `android/gradle/wrapper/*`, `android/gradlew`, `android/gradlew.bat`
- Create: `android/local.properties` (`sdk.dir=/Users/sangjoon/Library/Android/sdk`, gitignore 대상)
- Create: `android/app/src/main/AndroidManifest.xml` (Activity는 Task 4에서 추가)
- Create: `android/app/src/main/java/dev/submonitor/FlvReader.kt`
- Create: `android/app/src/test/java/dev/submonitor/FlvReaderTest.kt`
- Create: `android/app/src/test/resources/sample.flv`

**Interfaces:**
- Produces:
  ```kotlin
  sealed interface FlvEvent {
      class Config(val csd: ByteArray) : FlvEvent                    // VPS/SPS/PPS를 Annex-B로 이어 붙인 것
      class Frame(val data: ByteArray, val ptsMs: Long, val key: Boolean) : FlvEvent  // Annex-B 한 프레임
  }
  class FlvReader(input: InputStream) { fun next(): FlvEvent? }     // 스트림 끝이면 null
  ```

FFmpeg 9가 내보내는 실제 바이트 형식(확인함):
- 비디오 태그 첫 바이트의 최상위 비트가 1(확장 헤더)이다. `frameType = (b shr 4) and 7`(1 = 키프레임), `packetType = b and 0x0F`이고, 뒤에 fourcc `hvc1` 4바이트가 온다.
- 처리할 `packetType`:
  - 0 (SequenceStart): 본문이 `HEVCDecoderConfigurationRecord`(hvcC)다.
    - 길이 필드 크기 = `(hvcC[21] and 3) + 1`
    - `hvcC[22]` = 배열 수. 각 배열은 `type(1) numNalus(2) [len(2) nalu]*` 형식이다.
  - 1 (CodedFrames): fourcc 뒤 3바이트(composition time)를 건너뛴 다음부터 데이터
  - 3 (CodedFramesX): fourcc 바로 뒤부터 데이터
- 나머지(4 = 메타데이터 등)와 비디오가 아닌 태그(스크립트 18)는 건너뛴다.
- 데이터는 길이 접두 NAL들이다. 각 길이 필드를 `00 00 00 01`로 바꿔 Annex-B로 만든다.

- [ ] **Step 1: Gradle 준비**

`brew install gradle`을 한 번 실행한 뒤 `android/`에서 `gradle wrapper`를 실행한다.

AGP와 Kotlin 버전은 2026-11 기준 compileSdk 36을 지원하는 최신 안정판으로 정한다. 구현자가 Google Maven에서 확인한다.
- 라이브러리 의존성은 없다.
- `testImplementation("junit:junit:4.13.2")`만 둔다.

- [ ] **Step 2: 테스트 고정 파일(fixture) 생성**

Run: `ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=640x400:rate=30 -frames:v 3 -c:v hevc_videotoolbox -bf 0 -f flv android/app/src/test/resources/sample.flv`

이 명령을 `FlvReaderTest.kt` 상단 주석에 남긴다.

- [ ] **Step 3: 실패하는 테스트 작성** (`FlvReaderTest.kt`)

```kotlin
private val START = byteArrayOf(0, 0, 0, 1)

@Test fun parsesConfigThenThreeFramesFromFfmpegOutput() {
    val events = generateSequence(FlvReader(javaClass.getResourceAsStream("/sample.flv")!!)::next).toList()
    val config = events[0] as FlvEvent.Config
    assertArrayEquals(START + byteArrayOf(0x40, 0x01), config.csd.copyOf(6))   // VPS 먼저
    assertTrue(config.csd.indexOf(START + byteArrayOf(0x42, 0x01)) > 0)        // SPS 포함
    assertTrue(config.csd.indexOf(START + byteArrayOf(0x44, 0x01)) > 0)        // PPS 포함
    val frames = events.drop(1).map { it as FlvEvent.Frame }
    assertEquals(listOf(true, false, false), frames.map { it.key })
    assertEquals(listOf(0L, 33L, 67L), frames.map { it.ptsMs })
    frames.forEach { assertArrayEquals(START, it.data.copyOf(4)) }
}

@Test fun convertsLengthPrefixedNalsToAnnexB() {
    // 직접 만든 FLV: hvcC(길이 필드 4바이트, 배열 0개) + CodedFramesX 프레임 [len=2: 26 01][len=3: 02 01 AA]
    val frame = readFrames(flv(sequenceStart(lengthSize = 4), codedFramesX(nal(0x26, 0x01), nal(0x02, 0x01, 0xAA)))).single()
    assertArrayEquals(START + bytes(0x26, 0x01) + START + bytes(0x02, 0x01, 0xAA), frame.data)
}

@Test fun skipsCompositionTimeForCodedFrames() {
    val frame = readFrames(flv(sequenceStart(lengthSize = 4), codedFrames(cts = 0x000102, nal(0x26, 0x01)))).single()
    assertArrayEquals(START + bytes(0x26, 0x01), frame.data)
}
```

`flv`, `sequenceStart`, `codedFramesX`, `codedFrames`, `nal`, `bytes`, `readFrames`, `indexOf`는 같은 파일의 테스트 헬퍼다. 위의 바이트 형식대로 FLV 헤더, 태그, PreviousTagSize를 조립한다.

- [ ] **Step 4: 실패 확인**

Run: `cd android && ./gradlew testDebugUnitTest`
Expected: 컴파일 실패(`FlvReader` 미정의)

- [ ] **Step 5: `FlvReader` 구현**

`DataInputStream.readFully` 기반으로 짠다. 헤더의 DataOffset만큼 건너뛰고 PreviousTagSize0(4바이트)를 읽은 뒤 태그를 반복해서 읽는다.

- [ ] **Step 6: 테스트 통과 확인**

Run: `cd android && ./gradlew testDebugUnitTest`
Expected: 3개 PASS

- [ ] **Step 7: Commit**

```bash
git add android
git commit -m "feat(android): 프로젝트 골격과 Enhanced FLV(HEVC) 파서"
```

---

### Task 4: Android 디코딩·표시

세 번째 위험(S8 Ultra 디코더가 2960×1848@120 HEVC를 버티는가)을 확인한다.

**Files:**
- Create: `android/app/src/main/java/dev/submonitor/VideoDecoder.kt`
- Create: `android/app/src/main/java/dev/submonitor/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: `FlvReader`, `FlvEvent` (Task 3)
- Produces:
  - `class VideoDecoder(surface: Surface, width: Int, height: Int) { fun configure(csd: ByteArray); fun decode(frame: FlvEvent.Frame); fun release() }`
  - `MainActivity`(launcher, `dev.submonitor/.MainActivity`)
    - 루트는 `FrameLayout`이고, 그 안에 `SurfaceView`가 있다. Task 5가 같은 `FrameLayout`에 커서 오버레이를 얹는다.

- [ ] **Step 1: Manifest**

- `MainActivity` exported launcher로 등록한다.
- `android:screenOrientation="sensorLandscape"`로 둔다. 가상 디스플레이가 가로라서다.
- `configChanges="orientation|screenSize|screenLayout|keyboardHidden"`을 준다.
- 인터넷 권한은 필요 없다(localhost는 권한 불필요). 단, 실제로 막히면 `INTERNET`을 추가한다.

- [ ] **Step 2: `VideoDecoder` 구현**

- MediaCodec 설정:
  - `"video/hevc"` 디코더, `csd-0` = `config.csd`
  - `KEY_LOW_LATENCY = 1`
  - 출력은 생성자의 `surface`
- 출력 버퍼는 비동기 콜백에서 받는 즉시 `releaseOutputBuffer(index, true)`로 표시한다. 쌓지 않는다.
- 120프레임마다 `Log.i("submonitor", "fps=… decodeMs=…")`를 남긴다.
  - fps: 실제 출력 fps
  - decodeMs: `decode()` 투입부터 출력까지의 평균
- 코덱이 `FEATURE_LowLatency`를 지원하는지도 한 번 로그로 남긴다.

- [ ] **Step 3: `MainActivity` 구현**

화면 설정:
- `FLAG_KEEP_SCREEN_ON`
- 시스템 바 숨김(스와이프하면 잠시 보이게)
- `display.supportedModes` 중 2960×1848이면서 refreshRate ≥ 119인 모드를 `preferredDisplayModeId`로 지정
- Surface에 `setFrameRate(120f, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)`

영상 스레드:
- `surfaceCreated`에서 시작하고 `surfaceDestroyed`에서 소켓을 닫아 끝낸다.
- 반복: `Socket("127.0.0.1", 28100)`(`tcpNoDelay = true`) → `FlvReader`
  - `Config`를 받으면 디코더를 새로 만든다.
  - `Frame`을 받으면 `decode`한다.
  - 예외가 나면 디코더를 해제하고 500ms 뒤 다시 연결한다.

- [ ] **Step 4: 탭에서 확인 (위험 3)**

탭을 USB 디버깅 상태로 연결하고, 호스트를 실행 중(Task 2 `main.swift`)인 상태에서:

```bash
cd android && ./gradlew assembleDebug && cd ..
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb reverse tcp:28100 tcp:28100
adb shell am start -n dev.submonitor/.MainActivity
adb logcat -s submonitor
```

Expected:
- logcat에 `fps=`가 110 이상(가상 디스플레이에서 화면이 계속 바뀌는 동안), `decodeMs`는 한 자릿수에서 10ms대로 나온다.
- `adb exec-out screencap -p > <scratchpad>/tab.png` 결과에 mac 가상 디스플레이 내용이 꽉 차게 보인다.
- `adb shell dumpsys display | grep -i refresh`에서 120Hz가 확인된다.

**실패 시:** 디코더가 fps를 못 따라가면 호스트를 60fps로 다시 잰다. 그래도 안 되면 해상도를 낮춰 재고 결과를 기록한다(설계 문서의 대안 순서).

- [ ] **Step 5: Review Focus 1 확인**

- 탭에서 홈 버튼을 눌렀다가 앱으로 돌아오면 3초 안에 화면이 다시 나온다.
- 화면을 껐다 켜도 마찬가지다.

- [ ] **Step 6: Commit**

```bash
git add android
git commit -m "feat(android): MediaCodec 저지연 디코딩과 전체 화면 표시"
```

---

### Task 5: 커서 채널

**Files:**
- Create: `host/Sources/SubmonitorCore/CursorMessage.swift`
- Create: `host/Tests/SubmonitorCoreTests/CursorMessageTests.swift`
- Create: `host/Sources/submonitor/Cursor.swift` (`CursorServer`, `CursorTracker`)
- Modify: `host/Sources/submonitor/main.swift`
- Create: `android/app/src/main/java/dev/submonitor/CursorProtocol.kt`
- Create: `android/app/src/test/java/dev/submonitor/CursorProtocolTest.kt`
- Create: `android/app/src/main/java/dev/submonitor/CursorOverlay.kt`
- Modify: `android/app/src/main/java/dev/submonitor/MainActivity.kt`

**프로토콜 (TCP 28101, 호스트 → 탭, big-endian):** `type: u8, length: u32, payload[length]`
- `1` DISPLAY: `widthPt f32, heightPt f32`. 연결 직후 보낸다.
- `2` POSITION: `x f32, y f32, visible u8`. 가상 디스플레이 좌상단 기준 pt 좌표다.
- `3` SHAPE: `hotX f32, hotY f32, width f32, height f32`(모두 pt), 이어서 PNG 바이트(나머지 전부). 연결 직후와 모양이 바뀔 때 보낸다.
- 탭은 모르는 type을 받으면 payload를 건너뛴다.

**Interfaces:**
- Produces (`SubmonitorCore`, `public`):
  - `enum CursorMessage: Equatable { case display(width: Float, height: Float); case position(x: Float, y: Float, visible: Bool); case shape(hotX: Float, hotY: Float, width: Float, height: Float, png: Data); func encoded() -> Data }`
  - `func cursorPosition(global: CGPoint, displayBounds: CGRect) -> (x: Float, y: Float, visible: Bool)`
- Produces (`submonitor`):
  - `final class CursorServer { init(port: UInt16) throws; var onConnect: (() -> Void)?; func send(_ message: CursorMessage) }`
    - 클라이언트는 하나만 받는다. 새 연결이 오면 이전 연결을 닫는다.
  - `final class CursorTracker { init(displayID: CGDirectDisplayID, server: CursorServer); func start() }`
- Produces (Android):
  - `sealed interface CursorMsg { data class Display(val width: Float, val height: Float); data class Position(val x: Float, val y: Float, val visible: Boolean); class Shape(val hotX: Float, val hotY: Float, val width: Float, val height: Float, val png: ByteArray) }`
  - `fun readCursorMsg(input: DataInputStream): CursorMsg?` (스트림 끝이면 null)
  - `class CursorOverlay(context: Context) : View { fun update(msg: CursorMsg) }` (아무 스레드에서나 호출 가능)

- [ ] **Step 1: 실패하는 Swift 테스트 작성** (`CursorMessageTests.swift`)

이 바이트 배열 셋은 Kotlin 테스트에도 똑같이 들어간다. 두 언어 사이의 계약이다.

```swift
let displayBytes: [UInt8]  = [0x01, 0,0,0,8,  0x44,0xB9,0,0,  0x44,0x67,0,0]
let positionBytes: [UInt8] = [0x02, 0,0,0,9,  0x3F,0xC0,0,0,  0x40,0x00,0,0,  0x01]
let shapeBytes: [UInt8]    = [0x03, 0,0,0,0x12,  0x40,0x80,0,0, 0x40,0x80,0,0, 0x41,0x80,0,0, 0x41,0x80,0,0,  0xAA,0xBB]

func testEncodesGoldenBytes() {
    XCTAssertEqual([UInt8](CursorMessage.display(width: 1480, height: 924).encoded()), displayBytes)
    XCTAssertEqual([UInt8](CursorMessage.position(x: 1.5, y: 2, visible: true).encoded()), positionBytes)
    XCTAssertEqual([UInt8](CursorMessage.shape(hotX: 4, hotY: 4, width: 16, height: 16, png: Data([0xAA, 0xBB])).encoded()), shapeBytes)
}

// Review Focus 3: 경계
func testCursorPositionRelativeToDisplayAndHiddenOutside() {
    let b = CGRect(x: 1512, y: 0, width: 1480, height: 924)   // 메인 화면 오른쪽에 붙은 가상 디스플레이
    let inside = cursorPosition(global: CGPoint(x: 1512 + 10, y: 20), displayBounds: b)
    XCTAssertEqual(inside.x, 10); XCTAssertEqual(inside.y, 20); XCTAssertTrue(inside.visible)
    XCTAssertTrue(cursorPosition(global: CGPoint(x: 1512, y: 0), displayBounds: b).visible)        // 왼쪽 위 모서리는 안
    XCTAssertFalse(cursorPosition(global: CGPoint(x: 1511.5, y: 20), displayBounds: b).visible)    // 메인 화면 쪽
    XCTAssertFalse(cursorPosition(global: CGPoint(x: 1512 + 1480, y: 20), displayBounds: b).visible) // 오른쪽 끝은 밖
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --package-path host`
Expected: 컴파일 실패

- [ ] **Step 3: `CursorMessage.swift` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --package-path host`
Expected: 전체 PASS

- [ ] **Step 5: 실패하는 Kotlin 테스트 작성** (`CursorProtocolTest.kt`)

```kotlin
@Test fun decodesGoldenBytes() {
    val input = DataInputStream((displayBytes + positionBytes + shapeBytes).inputStream())
    assertEquals(CursorMsg.Display(1480f, 924f), readCursorMsg(input))
    assertEquals(CursorMsg.Position(1.5f, 2f, true), readCursorMsg(input))
    val s = readCursorMsg(input) as CursorMsg.Shape
    assertEquals(listOf(4f, 4f, 16f, 16f), listOf(s.hotX, s.hotY, s.width, s.height))
    assertArrayEquals(bytes(0xAA, 0xBB), s.png)
    assertNull(readCursorMsg(input))
}

@Test fun skipsUnknownType() {
    val input = DataInputStream((bytes(0x09, 0, 0, 0, 2, 0x11, 0x22) + positionBytes).inputStream())
    assertEquals(CursorMsg.Position(1.5f, 2f, true), readCursorMsg(input))
}
```

`displayBytes`, `positionBytes`, `shapeBytes`는 Step 1과 같은 값이다.

- [ ] **Step 6: 실패 확인 → `CursorProtocol.kt` 구현 → 통과 확인**

Run: `cd android && ./gradlew testDebugUnitTest`
Expected: 구현 전에는 컴파일 실패, 구현 후에는 전체 PASS

- [ ] **Step 7: 호스트 `Cursor.swift` 구현**

`CursorServer`:
- `NWListener`로 `127.0.0.1:28101`에서 받는다.
- `NWProtocolTCP.Options.noDelay = true`로 둔다.

`CursorTracker`:
- 메인 큐 `DispatchSourceTimer`로 4ms마다 `CGEvent(source: nil)?.location`을 읽는다.
- `cursorPosition`으로 변환하고 값이 바뀌었을 때만 `.position`을 보낸다.
- 50ms마다 `NSCursor.currentSystemCursor`의 이미지와 `hotSpot`을 PNG로 만들고, 이전과 다르면 `.shape`를 보낸다.
- `onConnect` 때는 `.display`(가상 디스플레이 pt 크기)와 현재 `.shape`를 보낸다.

**알려진 불확실성:** CLI 프로세스에서 `currentSystemCursor`가 다른 앱의 커서 모양을 돌려주는지는 확인하지 못했다. 안 되면 `NSCursor.arrow`를 한 번만 보내고, 그 사실을 기록한 뒤 진행한다.

`main.swift`에 서버와 트래커를 연결한다.

- [ ] **Step 8: Android `CursorOverlay`와 커서 스레드 구현**

`CursorOverlay`:
- 화면 배율은 `scale = view.width / Display.width`다.
- `Position`을 받으면 좌표를 저장하고 `postInvalidateOnAnimation()`을 부른다.
- `onDraw`에서 `(x - hotX) * scale, (y - hotY) * scale` 위치에 `width*scale × height*scale` 크기로 비트맵을 그린다. `visible = false`면 그리지 않는다.

`MainActivity`:
- 같은 `FrameLayout` 위에 오버레이를 얹는다.
- 커서 스레드를 Task 4의 영상 스레드와 같은 수명과 같은 재연결 방식으로 돌린다. `Socket("127.0.0.1", 28101)`, `tcpNoDelay = true`.

- [ ] **Step 9: 탭에서 확인**

`adb reverse tcp:28101 tcp:28101`을 추가하고 앱을 재설치한 뒤 실행한다.
- 마우스를 탭 화면으로 옮기면 커서가 즉시 따라온다. 영상보다 앞서 움직이는 것이 정상이다.
- 브라우저 입력란 위에서 커서가 텍스트 커서로, 링크 위에서 손가락으로 바뀐다.
- 커서를 메인 화면으로 옮기면 탭에서 사라지고, 잔상이 남지 않는다(Review Focus 3).

- [ ] **Step 10: Commit**

```bash
git add host android
git commit -m "feat: 커서를 영상과 분리해 탭에서 직접 그림"
```

---

### Task 6: 명령 하나로 실행

**Files:**
- Create: `host/Sources/SubmonitorCore/Options.swift`
- Create: `host/Tests/SubmonitorCoreTests/OptionsTests.swift`
- Create: `host/Sources/submonitor/Adb.swift`
- Modify: `host/Sources/submonitor/main.swift`
- Create: `run.sh`

**Interfaces:**
- Consumes: Task 1, 2, 5의 모든 호스트 타입
- Produces:
  - `public struct Options: Equatable { var fps = 120; var bitrate = "40M"; var apkPath: String? = nil; static func parse(_ args: [String]) throws -> Options }`
  - `func adb(_ args: String...) throws -> String` (`/usr/bin/env adb`, 종료 코드가 0이 아니면 throw)
  - `./run.sh [--fps N] [--bitrate R]`

- [ ] **Step 1: 실패하는 테스트 작성** (`OptionsTests.swift`)

```swift
func testDefaults() { XCTAssertEqual(try Options.parse([]), Options()) }
func testParsesFlags() {
    let o = try Options.parse(["--fps", "60", "--bitrate", "30M", "--apk", "a.apk"])
    XCTAssertEqual(o.fps, 60); XCTAssertEqual(o.bitrate, "30M"); XCTAssertEqual(o.apkPath, "a.apk")
}
func testRejectsUnknownFlagAndBadFps() {
    XCTAssertThrowsError(try Options.parse(["--nope"]))
    XCTAssertThrowsError(try Options.parse(["--fps", "abc"]))
}
```

- [ ] **Step 2: 실패 확인 → `Options.swift` 구현 → 통과 확인**

Run: `swift test --package-path host`
Expected: 구현 전에는 컴파일 실패, 구현 후에는 전체 PASS

- [ ] **Step 3: `Adb.swift`와 기기 감시 루프 구현**

백그라운드 스레드에서 반복한다:
1. `탭 연결 대기 중… (USB 디버깅 허용 확인)`을 출력한다.
2. `adb wait-for-device`
3. `adb reverse tcp:28100 tcp:28100`, `adb reverse tcp:28101 tcp:28101`
4. `apkPath`가 있으면 그 프로세스에서 처음 한 번만 `adb install -r <apk>`
5. `adb shell am start -n dev.submonitor/.MainActivity`
6. `adb wait-for-disconnect` 후 1번으로 돌아간다.

USB를 다시 꽂으면 reverse 설정이 사라지기 때문에 이 루프가 필요하다(Review Focus 2).

- [ ] **Step 4: 최종 `main.swift` 흐름**

1. `Options.parse(Array(CommandLine.arguments.dropFirst()))`
2. `pkill -f "tcp://127.0.0.1:28100"`로 남은 FFmpeg를 정리한다(Review Focus 5).
3. 가상 디스플레이 생성
4. 커서 서버와 트래커 시작
5. `FFmpegRunner` 시작(`options.fps`, `options.bitrate`)
6. 기기 감시 루프 시작

SIGINT/SIGTERM을 받으면:
- `runner.stop()`
- `adb reverse --remove tcp:28100`, `adb reverse --remove tcp:28101`
- `adb shell am force-stop dev.submonitor`
- `exit(0)`

종료 시 adb 오류는 무시한다(탭이 이미 빠졌을 수 있음).

- [ ] **Step 5: `run.sh`**

```bash
#!/bin/sh
set -e
cd "$(dirname "$0")"
(cd android && ./gradlew -q assembleDebug)
swift build -c release --package-path host
exec host/.build/release/submonitor --apk android/app/build/outputs/apk/debug/app-debug.apk "$@"
```

`chmod +x run.sh`

- [ ] **Step 6: 처음부터 끝까지 확인**

Run: `adb uninstall dev.submonitor; ./run.sh`
Expected: 10초 안에 탭에 mac 확장 화면과 커서가 나온다.

Review Focus 2:
- 실행 중 USB를 뺀다. 호스트는 계속 살아 있고 `탭 연결 대기 중…`을 출력한다.
- 다시 꽂으면 5초 안에 화면이 복구된다.

Review Focus 5:
- `kill -9 <submonitor PID>`로 호스트를 강제 종료한다. FFmpeg가 남는다.
- `./run.sh`를 다시 실행해도 포트 충돌 없이 시작된다.

Ctrl-C:
- 가상 디스플레이가 사라진다.
- `pgrep -f tcp://127.0.0.1:28100` 결과가 비어 있다.

- [ ] **Step 7: Commit**

```bash
git add host run.sh
git commit -m "feat: run.sh 한 번으로 빌드·설치·연결·재연결 처리"
```

---

### Task 7: 지연 측정 도구와 사용법

**Files:**
- Create: `tools/latency-clock.html`
- Create: `README.md`

- [ ] **Step 1: `latency-clock.html`**

- 화면 가득 큰 고정폭 글자로 `Date.now() % 100000`(ms)를 `requestAnimationFrame`마다 표시한다.
- 외부 리소스는 쓰지 않는다.
- 측정할 때는 브라우저 창 두 개로 열어 하나는 메인 화면, 하나는 탭 화면에 둔다. 복제(미러링) 모드가 필요 없다.

- [ ] **Step 2: `README.md`**

다음 내용만 쓴다.
- 준비: 탭 USB 디버깅, 터미널 앱의 화면 기록 권한, `ffmpeg`·`adb`가 PATH에 있어야 함
- 실행: `./run.sh`, `--fps 60`, `--bitrate`
- 지연 측정법: 시계 창 두 개를 휴대폰으로 함께 촬영해 차이를 읽음
- 1차 범위: mac 전용, 터치·S Pen 없음
- 측정 결과를 적을 빈 표

- [ ] **Step 3: 사용자 측정 (사용자가 수행)**

사용자에게 다음을 요청하고, 결과를 README 표에 적는다.
- 측정 3회의 화면 지연 값
- 실제 브라우저 작업 체감(커서 이동, 스크롤, 타이핑)
- 탭에서 브라우저 글자가 선명하게 읽히는지(실패 기준 2). 뭉개지면 `--bitrate`를 올려 다시 확인한다.

합격 판정은 체감이다(설계 문서 '합격 기준'). 불합격이면 단계별 시간을 재서 병목을 찾는 별도 계획으로 넘긴다.

- [ ] **Step 4: Commit**

```bash
git add tools README.md
git commit -m "docs: 지연 측정 시계와 사용법"
```
