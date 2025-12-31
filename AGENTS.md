# Stablecoin Shared Server Runtime — Design Doc (v1.4)

## 0. One-liner
事前に「起動したいインスタンス（予約枠）」を定義し、  
各インスタンスに対して「人数・開始時刻・稼働時間」を持つセッションを作る。

開始時刻に **全員分の必要デポジットが揃っていれば Active** になり、
Controller がサーバを起動する。

- 超過入金分はいつでも引き出し可能  
- 開始時刻までに人数が揃わなければ全額返金可能  
- Provider のオンチェーン操作は原則 `withdraw` のみ  

---

## 1. Plan と rate の定義（初期化時に固定）

### 1.1 Plan enum
```solidity
enum Plan {
    Small,
    Medium,
    Large
}
```

### 1.2 ratePerSecond
Plan ごとの料金（USDC / 秒）を constructor で設定する。

```solidity
mapping(Plan => uint256) public ratePerSecond;
```

### 1.3 コンストラクタ初期化
```solidity
constructor(
    uint256 smallRate,
    uint256 mediumRate,
    uint256 largeRate
) {
    ratePerSecond[Plan.Small]  = smallRate;
    ratePerSecond[Plan.Medium] = mediumRate;
    ratePerSecond[Plan.Large]  = largeRate;
}
```

例（USDC = 6 decimals）  
- small: 1 USDC / hour → `1e6 / 3600`  
- medium: 3 USDC / hour → `3e6 / 3600`  
- large: 8 USDC / hour → `8e6 / 3600`

---

## 2. Instance（起動枠）

Instance は「将来起動される計算リソースの枠」。

### Instance 構造
- instanceId
- planId
- provider（支払先）
- enabled

```solidity
struct Instance {
    Plan planId;
    address provider;
    bool enabled;
}
```

### createInstance
```solidity
createInstance(planId, provider) -> instanceId
```

- 誰でも作成可能（サンプル仕様）
- planId は enum 範囲チェック
- provider は報酬受取先
- enabled = true で初期化

---

## 3. Session（募集・稼働単位）

Instance に紐づく 1 回の利用単位。

### Session 構造
- sessionId
- instanceId
- maxParticipants
- startAt
- durationSec
- requiredPerUser
- readyCount
- totalDeposited
- withdrawnGross
- status

```solidity
enum SessionStatus {
    Funding,
    Active,
    Cancelled,
    Closed
}
```

---

## 4. requiredPerUser の計算

Session 作成時に一度だけ確定する。

```
totalRequired = ratePerSecond[planId] * durationSec
requiredPerUser = ceil(totalRequired / maxParticipants)
```

- 切り上げ方式
- 余剰は後でユーザーに返金される
- 以後この値は変更されない

---

## 5. Session 作成

### createSession(instanceId, maxParticipants, startAt, durationSec)

条件:
- instance.enabled == true
- startAt > now
- maxParticipants > 0
- durationSec > 0

処理:
- instance から planId を取得
- ratePerSecond を参照
- requiredPerUser を計算
- status = Funding

---

## 6. 参加と入金

### join(sessionId)
- status == Funding
- now < startAt
- 先着 maxParticipants

---

### deposit(sessionId, amount)

- status == Funding
- now < startAt
- USDC transferFrom
- participant.deposited += amount
- totalDeposited += amount

ready 判定:
- これまで `deposited < requiredPerUser`
- 今回の入金で `deposited >= requiredPerUser`
- 上記を初めて満たした場合 `readyCount++`

---

## 7. 返金ルール（重要）

### 7.1 超過分の引き出し（いつでも可）

#### withdrawExcess(sessionId, amount)

目的：
- 必要額を超えた分だけを自由に引き出せるようにする

条件:
- participant.deposited - amount >= requiredPerUser

処理:
- participant.deposited -= amount
- totalDeposited -= amount
- USDC を送金

※ requiredPerUser 未満になる引き出しは禁止  
→ readyCount を減らす処理が不要になり、実装が単純になる

---

### 7.2 開始されなかった場合の全額返金

#### withdrawIfNotStarted(sessionId)

条件:
- now >= startAt
- status != Active  
  （または `readyCount != maxParticipants`）

処理:
- refund = participant.deposited
- participant.deposited = 0
- totalDeposited -= refund
- USDC 返金

※ 各ユーザーが自分で呼ぶ  
※ 多重請求は deposited = 0 にすることで防止

---

## 8. 開始確定（permissionless）

### finalize(sessionId)

誰でも呼び出し可能（Controller想定）

条件:
- status == Funding
- now >= startAt

分岐:
- readyCount == maxParticipants  
  → status = Active  
  → startTime = startAt
- それ以外  
  → status = Cancelled

---

## 9. 終了処理（permissionless）

### closeIfExpired(sessionId)

条件:
- status == Active
- now >= startTime + durationSec

処理:
- status = Closed

---

## 10. Provider の報酬引き出し

### providerWithdraw(sessionId)

条件:
- status == Active または Closed

計算:
```
stopAt = startTime + durationSec
t = min(now, stopAt)

unlocked =
  min(
    (t - startTime) * ratePerSecond[planId],
    totalDeposited
  )

withdrawable = unlocked - withdrawnGross
```

処理:
- withdrawnGross += withdrawable
- USDC を instance.provider に送金

---

## 11. 返金（終了後の余剰分）

### refundClosed(sessionId)

条件:
- status == Closed

計算:
```
finalUnlocked = min(durationSec * ratePerSecond, totalDeposited)
refundableTotal = totalDeposited - finalUnlocked
refund = refundableTotal * participant.deposited / totalDeposited
```

処理:
- participant.deposited = 0
- USDC 返金

---

## 12. Controller（Off-chain）

### 監視ロジック
- now >= startAt → finalize(sessionId)
- status == Active && now >= stopAt → closeIfExpired(sessionId)

### 起動制御
- Active になったら instance.planId に応じて compute 起動
- stopAt 到達で compute 停止

---

## 13. 設計のポイント

- rate は constructor で固定（ガバナンス不要）
- plan は enum で固定
- instance = 起動枠
- session = 人数＋時間を伴う予約
- startAt が唯一の確定タイミング
- provider は withdraw だけ
- finalize / close は permissionless
- 超過分は常に withdraw 可能
- 不成立時は全額返金可能

---

## 14. v2 候補
- allowlist / 署名参加
- 途中参加・延長
- dynamic pricing
- deposit の部分引き出し（readyCount 再計算あり）
- マルチトークン対応
