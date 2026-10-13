# 구현 가능성 및 CoreUI 결정

[한국어](FEASIBILITY.md) | [English](FEASIBILITY.en.md)

상태: **실험적 베타 — 비공개 API, FINGERPRINT 제한**

## 검증된 기준 환경

Intel 검증 장비는 macOS 13.7.8(22H730)을 실행합니다. 공식 카카오톡 26.8.0(2000)의 bundle identifier는 `com.kakao.KakaoTalkMac`, Team ID는 `L75WVXX68A`이며 strict deep signature가 유효하고 실행 파일은 Universal x86_64/arm64입니다. asset 이외의 정확한 호환성 정보는 `compatibility.json`에 기록되어 있습니다.

Dock 아이콘은 공개 AppKit으로 번들의 `.icns`를 읽어 노란색 배경만 초록색으로 바꾼 뒤 `/usr/bin/iconutil`로 다시 만들고 staged copy에서 교체합니다. catalog 지문에는 의존하지 않지만 미래 버전의 아이콘 구조까지 보장하지는 않습니다. Intel macOS 13, KakaoTalk 26.8.0(2000)의 수정본에서 설치와 두 로그인 화면의 동시 표시를 확인했고, 사용자는 초록색 Dock 아이콘을 확인했습니다. 촬영 당시 `⌘Tab`은 노란색이었으며 원인은 확정하지 않았습니다. 로그인·메시지 송수신 및 수정본의 Apple Silicon 실기기 검증은 수행하지 않았습니다. 초록색 메뉴 막대 상태는 `Contents/Resources/Assets.car`에 있으며 공개 writer API가 없어 검증된 지문에서만 처리합니다.

## 현재 구현

프로젝트 소유자가 비공개 API 위험을 명시적으로 수용했습니다. 따라서 베타는 문서화되지 않은 CoreUI class를 호출하는 작은 Objective-C bridge를 사용합니다. 이 bridge는 다음 원칙을 따릅니다.

- 허용 목록의 원본 catalog SHA-256과 정확히 일치할 때만 처리
- 1x 및 2x의 이름 지정 메뉴 아이콘 8개만 대상 지정
- 변경 전 예상 dimension과 link 구조 확인
- 공식 앱이 아닌 staged copy만 변경
- 결과 catalog를 검증하고 hash가 변경되었는지 확인
- 교체 전 완성된 staged app을 서명하고 검증
- 실패하면 이전 `KakaoTalkWork.app`으로 rollback

bridge 선언은 관찰한 runtime selector와 MIT 라이선스 CoreUI header 정보를 바탕으로 독립 구현했습니다. 제3자 구현, 카카오 실행 파일 또는 카카오 asset byte를 vendoring하지 않습니다.

## 잔여 위험

CoreUI는 비공개이므로 macOS 업데이트에서 변경될 수 있습니다. Catalog 내부 구조도 카카오톡 업데이트에서 바뀔 수 있습니다. Ad-hoc 서명은 보안 경고를 유발할 수 있습니다. 기존 버전의 Universal 결과물은 Intel macOS 13.7.8과 Apple M3 macOS 26.5.2에서 검증했습니다. 수정본은 별도 실기기 검증이 필요합니다. 알 수 없는 catalog에서는 메뉴 아이콘 변경만 생략하며, 번들 구조·신원·서명 검증 실패는 설치를 중단합니다.

## 후속 작업

별도로 추적하는 목표에서 필요한 `Assets.car` 부분만 처리하는 독립 writer를 연구합니다. 가능한 경우 대상 외 record를 byte 단위로 보존하고, round-trip 및 손상 테스트를 제공하며, 동등성이 입증된 뒤에만 비공개 bridge를 대체해야 합니다. 그전까지 비공개 bridge는 실험적 구현으로 명확히 표시합니다.
