<p align="right"><a href="google-maps-key.md">English</a> · <b>한국어</b></p>

# 내 Google 지도 키 쓰기

Afterplate는 식사 사진 근처의 가게를 Google 지도 검색으로 찾아요. 기본으로는 맥마다 Afterplate 검색을 일주일 몫(방문 15개쯤)씩 나눠 쓰고, 매주 월요일(UTC)에 다시 채워져요. 처음 실행하고 평소에 쓰기에는 충분해요. 이번 주 몫을 다 쓰면 방문은 다음 주까지 기다려요.

기다리기 싫으면 **설정 › 가게 검색**에 내 키를 넣으세요. 그러면 내 키로 찾고, Google이 프로젝트마다 매달 주는 무료 호출 안에서 써요.

## 키 받기 (10분쯤)

1. **프로젝트 만들기**: [console.cloud.google.com/projectcreate](https://console.cloud.google.com/projectcreate)
2. **결제 계정 연결**: [console.cloud.google.com/billing](https://console.cloud.google.com/billing). 무료 호출만 써도 Google은 카드를 요구해요. 무료 한도 안에서는 청구되지 않아요.
3. **Places API (New) 사용 설정**: [console.cloud.google.com/apis/library/places.googleapis.com](https://console.cloud.google.com/apis/library/places.googleapis.com)
4. **키 만들기**: [console.cloud.google.com/apis/credentials](https://console.cloud.google.com/apis/credentials) → *사용자 인증 정보 만들기* → *API 키*. *API 제한사항*에서 **Places API (New)**만 허용하세요.
5. **선택이지만 권장: 상한 걸기.** [할당량 페이지](https://console.cloud.google.com/apis/api/places.googleapis.com/quotas)에서 *SearchNearby requests per day*를 150쯤으로 (*SearchText*도 똑같이) 정하세요. 그러면 버그가 있어도 무료 호출을 넘지 않아요.
6. 키를 **설정 › 가게 검색 › 내 Google 지도 키**에 붙여 넣고 *저장*을 누르세요. 키는 macOS 키체인에 보관돼요.

## 앱이 Google에 묻는 것

| 호출 | 언제 | Google 등급 |
|---|---|---|
| Nearby Search | 방문마다 한 번, 가게가 빽빽한 곳은 두 번 | Pro |
| 리뷰를 포함한 Nearby Search | 가게 종류만으로 근처 후보 둘을 가를 수 없을 때 | Enterprise |
| Text Search | 가게를 이름으로 찾을 때 | Pro |
| Place Details (위치만) | 고른 가게를 지도에 놓을 때 | Essentials |

2026년 10월 기준 Google의 월 무료 호출(Pro 5,000, Enterprise 1,000, Essentials 10,000번)로, 키 하나로 한 달에 방문 2,500개쯤 찾을 수 있어요.

설정에서 키를 지우면 다시 Afterplate 몫을 써요.
