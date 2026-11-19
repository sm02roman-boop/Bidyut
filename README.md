# Bidyut — NESCO Prepaid Meter Dashboard · v1.0

## দ্রুত শুরু

| কী করবেন | ফাইল |
|---|---|
| iPhone-এ তোলা (Xcode বা Sideloadly) | **INSTALL.md** |
| Sideloadly-র জন্য .ipa বানানো | `./build-ipa.sh` |
| ঘণ্টাভিত্তিক ডেটা জমানোর server | **server/README.md** |

```bash
brew install xcodegen
xcodegen generate     # Sideloadly / paid account
./build-ipa.sh        # → build/Bidyut.ipa
```

Free Apple ID দিয়ে Xcode থেকে সরাসরি: `xcodegen generate --spec project-free.yml`

## v1.0-তে যা আছে

- NESCO portal থেকে balance, রিচার্জ, ৬ মাসের monthly — আসল মিটারে যাচাই করা
- Tariff engine — এই মিটারের বিল আধা পয়সায় মেলে; ৪০০ ইউনিটের cliff সতর্কতা
- Friendly Hour — balance শূন্য নয়, লাইন **কখন আসলে কাটবে** সেটা বলে
- Burn rate, কত দিন চলবে, kWh/watt (derived), recharge পরামর্শ
- Recharge sheet: গ্রাহক নম্বর কপি, USSD, ২০-digit টোকেন, ১৬৬০৩
- ব্যর্থ রিচার্জ alert, বিল অডিট, অস্বাভাবিক খরচ ধরা
- Widget (refresh বাটন সহ), Live Activity, Siri, স্মার্ট notification
- বাংলা / English, বাংলা অঙ্কে সংখ্যা
- App icon — Any, Dark, Tinted
- Zero-dependency Node server, ১৫ মিনিটে poll

---


নিজের NESCO প্রিপেইড মিটারের balance, daily burn rate, "আর কত দিন চলবে" forecast আর recharge breakdown — একটা native iOS app-এ, Home Screen widget সহ।

কোনো server লাগে না। App সরাসরি আপনার iPhone থেকে NESCO customer portal-এ request পাঠায়।

---

## Build করবেন যেভাবে

MacBook-এ Xcode 15+ লাগবে (iOS 17 deployment target)।

```bash
brew install xcodegen          # একবারই
cd Bidyut
xcodegen generate              # Bidyut.xcodeproj তৈরি হবে
open Bidyut.xcodeproj
```

Xcode-এ তিনটা জিনিস set করতে হবে:

1. **Signing** — `Bidyut` আর `BidyutWidgetExtension` দুটো target-এই Signing & Capabilities → আপনার Apple ID team select করুন।
2. **App Group** — দুটো target-এই App Groups capability-তে `group.com.codeyo.bidyut` আছে কিনা দেখুন। Widget এটা দিয়েই app-এর data পড়ে।
3. **Bundle ID** — Free Apple ID হলে `com.codeyo.bidyut` হয়তো নিতে দিবে না। নিজের মতো একটা দিন (যেমন `com.shihan.bidyut`), আর `SharedStore.appGroupID` + `project.yml`-এ group ID-ও মিলিয়ে বদলে দিন।

Free Apple ID দিয়ে build করলে app ৭ দিন পর expire করবে — আবার Xcode থেকে run করলেই চলবে। $99/year developer account নিলে এই ঝামেলা নেই।

---

## কীভাবে কাজ করে

NESCO-র কোনো public API নেই। Portal সব server-side render করে, একটা CSRF token + session cookie-র ভেতরে। App সেই browser flow-টাই নকল করে:

```
1. GET  customer.nesco.gov.bd/pre/panel
       → <meta name="csrf-token"> থেকে token, Set-Cookie থেকে session

2. POST customer.nesco.gov.bd/pre/panel
       _token  = <token>
       cust_no = <আপনার customer number>
       submit  = "রিচার্জ হিস্ট্রি"        → customer info + recharge rows
       submit  = "মাসিক ব্যবহার"          → monthly consumption table

3. HTML parse
```

সব HTML parsing একটা ফাইলেই — `Sources/Network/NescoParser.swift`। NESCO portal redesign করলে শুধু ওই ফাইলটা ঠিক করলেই হবে, বাকি app অক্ষত থাকবে।

### গুরুত্বপূর্ণ দুটো constraint

**Portal শুধু Bangladesh থেকে খোলে.** বাইরের IP বা VPN-এ 403 আসবে। App এই error আলাদা করে ধরে আর VPN বন্ধ করতে বলে।

**NESCO daily consumption দেয় না — শুধু monthly.** তাই daily burn rate app নিজে হিসাব করে: প্রতিবার sync-এ একটা balance snapshot জমা রাখে, তারপর পরপর দুটো snapshot-এর পার্থক্য থেকে খরচ বের করে, মাঝখানে recharge হলে সেটা যোগ করে নেয়:

```
consumed = আগের balance + মাঝে credited − এখনকার balance
```

এখানে "credited" মানে recharge-এর **electricity portion**, মোট টাকা নয় — NESCO meter rent, demand charge আর VAT আগেই কেটে নেয়। Recent intervals বেশি weight পায় (২১ দিনের half-life), কারণ গরমকালের খরচ শীতকালের মতো না।

**প্রথম দিন থেকেই forecast কাজ করে.** Monthly table-এ "মাস শেষে মিটার ব্যালেন্স" বলে একটা column আছে — NESCO প্রতি মাস শেষের balance রেকর্ড করে রাখে। App প্রথম sync-এই সেগুলো থেকে ৬ মাসের balance history তৈরি করে নেয়, তাই দিন গুনে অপেক্ষা করতে হয় না।

### Monthly table-এর ১৩টা column

`বছর · মাস · সর্বমোট রিচার্জ · রেয়াত · ব্যবহৃত বিদ্যুৎ (টাকা) · মিটার রেন্ট · ডিমান্ড চার্জ · পিএফসি · পরিশোধিত বকেয়া · ভ্যাট · সর্বমোট কর্তন · মাস শেষে ব্যালেন্স · ব্যবহৃত বিদ্যুৎ (কি.ও.আ.)`

Column গুলো header text দেখে চেনা হয়, position দেখে নয় — কারণ NESCO মাঝে একটা কলাম যোগ করলেও তাতে parser ভাঙে না।

---

## কী কী আছে

| | |
|---|---|
| **Balance hero** | বড় করে current balance, days-left অনুযায়ী রঙ। Negative হলে "emergency balance in use" |
| **Forecast** | আর কত দিন চলবে, দিনে কত খরচ, কবে শেষ হবে। সাথে confidence label |
| **Recharge suggestion** | এক মাস চালাতে কত রিচার্জ দরকার — fixed charges সহ, ১০০ টাকায় round |
| **Charts** | ৩০ দিনের balance trend, estimated daily spend, NESCO-র monthly units |
| **Recharge history** | প্রতিটা recharge-এ কত meter rent, demand charge, VAT কাটলো — আর কত % টাকা deduction-এ গেল |
| **Widget** | Home Screen (small/medium) + Lock Screen (circular/rectangular/inline) |
| **Alerts** | Threshold-এর নিচে নামলে, আর balance শেষ হওয়ার ~২ দিন আগে forecast-ভিত্তিক warning |
| **Multi-meter** | বাসা, chamber, office — একাধিক meter |

---

## Project structure

```
Sources/
  Network/      NescoDTO · NescoParser · NescoClient     ← portal protocol
  Models/       SwiftData models (Meter, snapshots, recharges, monthly)
  Analytics/    ConsumptionAnalytics                      ← burn rate + forecast
  Services/     SyncService · NotificationService · SharedStore
  Views/        Dashboard · Charts · AddMeter · History · Settings
  Support/      Theme · Formatters
Widget/         WidgetKit extension
Tests/          Parser + analytics tests
```

Widget target শুধু তিনটা ফাইল share করে (`SharedStore`, `Theme`, `Formatters`) — SwiftData বা networking layer widget-এ ঢোকে না। App প্রতি sync-এ App Group-এ একটা ছোট JSON লিখে, widget শুধু সেটাই পড়ে।

---

## Tests

```bash
xcodebuild test -scheme Bidyut -destination 'platform=iOS Simulator,name=iPhone 15'
```

Parser tests NESCO-র আসল markup shape-এর উপর চলে, আর analytics tests forecast-এর অঙ্কটা যাচাই করে — যেমন recharge মাঝে পড়লে consumption ঠিকমতো হিসাব হচ্ছে কিনা, আর balance অকারণে বেড়ে গেলে সেই reading বাদ পড়ছে কিনা।

---

## Units, kilowatts আর "real-time"

সোজা কথা: **NESCO live meter reading দেয় না।** Portal-এ instantaneous load নেই, daily kWh feed নেই, কোনো push বা websocket নেই। যা আছে — balance, recharge history (প্রতি recharge-এ kWh), আর monthly total।

তাই unit আর watt **derive করা হয়**, আর app সেটা স্পষ্ট করেই বলে — meter telemetry হিসেবে চালিয়ে দেয় না।

সেতুটা হলো **effective rate**: পুরো একটা শেষ হওয়া মাসে NESCO আসলে কত নিয়েছে।

```
effective rate = ওই মাসের বিদ্যুৎ খরচ (টাকা) ÷ ওই মাসের ইউনিট
               = 3614.77 ÷ 419.039
               = ৳8.63 per kWh        (October 2026)

units/day   = দৈনিক টাকা খরচ ÷ rate  = 116.60 ÷ 8.63 = 13.5 kWh
avg watts   = units/day ÷ 24 × 1000                  = 563 W
units left  = balance ÷ rate          = 229.97 ÷ 8.63 = 26.6 kWh
load share  = 563 W ÷ 2000 W sanctioned               = 28%
```

Published slab rate-এর বদলে effective rate নেওয়ার কারণ — এটায় আপনার বাসা আসলে কোন slab-এ পড়েছে সেটা আগে থেকেই ধরা আছে। চলতি মাস বাদ দেওয়া হয়, কারণ তার total এখনো বাড়ছে।

`LiveMonitor` app খোলা থাকলে ১৫ মিনিট পরপর portal poll করে আর balance নামা দেখে। Portal-এর balance এর চেয়ে দ্রুত update হয় না, তাই এর বেশি ঘন ঘন poll করলে একই সংখ্যা ফিরবে — শুধু সরকারি সার্ভারে চাপ বাড়বে।

**আরও ঘন data চাইলে একটা server লাগবে.** ফোন বন্ধ থাকলে app poll করতে পারে না, তাই history-তে ফাঁক থাকবে। একটা ছোট VPS প্রতি ১৫ মিনিটে poll করলে দিনে ~৯৬টা reading জমবে, তখন ঘণ্টাভিত্তিক usage curve বানানো সম্ভব — ওই Telegram bot এভাবেই কাজ করে।

---

## Tariff engine — স্ল্যাব আর cliff

Bangladesh-এ residential বিল **progressive slab**-এ হয়: মাসের প্রতিটা ব্যান্ড আলাদা rate-এ। <br>
BERC-র rate সব distributor-এর জন্য এক, NESCO সহ।

| মাসিক ইউনিট | ৳/ইউনিট |
|---|---|
| ০–৫০ (lifeline, flat) | ৪.৬৩ |
| ১–৭৫ | ৫.২৬ |
| ৭৬–২০০ | ৮.৫০ |
| ২০১–৩০০ | ৯.১০ |
| ৩০১–৪০০ | ৯.৬২ |
| **৪০১–৬০০** | **১৫.০১** |
| ৬০১+ | ১৭.৩৫ |

Demand charge ৳৪২/kW/মাস · VAT ৫% · prepaid rebate ০.৫%

**এই meter-এর নিজের বিল দিয়ে যাচাই করা:**

```
October   419.039 ইউনিট → computed ৳3,614.78 | NESCO নিয়েছে ৳3,614.77
September 391.039 ইউনিট → computed ৳3,242.80 | NESCO নিয়েছে ৳3,242.80
```

আধা পয়সার পার্থক্য — rounding। এই মিল থাকার কারণেই app আন্দাজ নয়, আসল projection দেখাতে পারে।

**৪০০ ইউনিটের cliff** সবচেয়ে গুরুত্বপূর্ণ: ৯.৬২ থেকে ১৫.০১, এক ধাপে ৫৬% লাফ। অক্টোবরে এই meter ৪১৯.০৩৯ ইউনিটে গিয়ে cliff-এর ১৯ ইউনিট ওপরে ছিল — ওই ইউনিটগুলোর দাম ৳২৮৫.৭৮, যার ৳১০২.৬২ শুধুই slab জরিমানা। App মাসের মাঝপথেই সতর্ক করে, আর বলে দেয় বাকি দিনগুলোয় দিনে কত ইউনিটে থাকলে line পার হবে না।

`marginalRate` — পরের ইউনিটটা কত দামে পড়বে। AC চালাবো কিনা, এই সিদ্ধান্তে এটাই আসল সংখ্যা; মাসের গড় সবসময় কম দেখায়।

---

## Friendly Hour — বিদ্যুৎ আসলে কখন যাবে

Balance শূন্য হলেই লাইন কাটে না। NESCO-র নিজের FAQ অনুযায়ী প্রতিদিন **বিকাল ৪:০০ থেকে পরদিন সকাল ১১:০০** Friendly Hour, আর শুক্র-শনি সহ সব সরকারি ছুটি **২৪ ঘণ্টা** Holiday। এই সময়ে balance শেষ হলেও সরবরাহ চলে, খরচটা negative balance হিসেবে জমা থাকে আর পরের recharge থেকে কাটা যায়।

মানে লাইন কাটার window আসলে **রবি–বৃহস্পতি, সকাল ১১টা–বিকাল ৪টা** — দিনে মাত্র ৫ ঘণ্টা।

`SupplyPredictor` এটা হিসাব করে বলে: "শুক্রবার দুপুরে balance শেষ হবে, কিন্তু রবিবার সকাল ১১টার আগে লাইন কাটবে না — প্রায় ৪৫ ঘণ্টা হাতে, ~৳২২০ negative জমবে।" এটাই আতঙ্ক আর শান্ত থাকার পার্থক্য।

Emergency balance keypad-এ **99999** চেপে (single-phase ~৳২০০, three-phase ~৳৫০০), পরের recharge থেকে কাটা যায়।

---

## Siri আর Shortcuts

- *"What is my Bidyut balance"* → balance sync করে বলে দেয়, সাথে days left আর Friendly Hour-এর কথা
- *Running cost* intent → watt আর ঘণ্টা দিলে **marginal rate**-এ খরচ বলে

অ্যাপ না খুলেই balance জানা — দিনে কয়েকবারের কাজটা এতে ১০ সেকেন্ডে নামে।

---

## অভিজ্ঞতা মসৃণ করার ফিচার

**বাংলা** — Settings থেকে ভাষা বদলানো যায়, সাথে সাথে, অ্যাপ বন্ধ না করেই। বাংলায় সংখ্যাও বাংলা অঙ্কে: ৳২২৯.৯৭, ১৩.৫ ইউনিট। Widget-ও বদলায়। মূল স্ক্রিনগুলো ঢাকা পড়েছে; গভীরের কিছু string এখনো ইংরেজি।

**Recharge sheet** — ব্যালেন্সের ঠিক নিচে এক ট্যাপ। গ্রাহক নম্বর কপি, bKash/Nagad খোলা (`canOpenURL` দিয়ে যাচাই করে, না থাকলে fallback), আর USSD কোড `*247#` / `*167#` সরাসরি ডায়াল।

**টোকেন কার্ড — সবচেয়ে কাজের সংযোজন।** রিচার্জ সফল দেখালেও মিটারে টাকা না উঠলে ২০-digit token হাতে লিখতে হয়। ওই token portal থেকে আগেই চলে আসে, তাই অ্যাপ সেটা চার-চার করে ভাগ করে দেখায়, কপি বাটন সহ। SMS খুঁজতে হবে না।

**ব্যর্থ রিচার্জ ধরা** — নতুন failed recharge এলে notification: তারিখ, পরিমাণ, মাধ্যম, আর নেসকো **১৬৬০৩**-এ কল করার বাটন। এই মিটারের ইতিহাসে চারটা failed রিচার্জ আছে, ৮ নভেম্বরের ৳১৫০০ সহ — টাকা কেটে থাকলে এটাই জানার একমাত্র উপায়।

**Live Activity** — শেষ ~২.৫ দিনে Lock Screen-এ countdown, Dynamic Island-এ ব্যালেন্স। রিচার্জ হলে নিজে থেকে চলে যায়। যে দিনগুলোয় মানুষ পাঁচবার ব্যালেন্স দেখে, সেই পাঁচবার শূন্যে নামে।

**Widget-এ refresh বাটন** — Home Screen থেকেই আপডেট (iOS 17 interactive widget)।

**স্মার্ট notification timing** — সতর্কবার্তা আসে লাইন কাটার ১২ ঘণ্টা আগে, Friendly Hour হিসাব করে। রাত ১১টা–সকাল ৭টার মধ্যে পড়লে সকাল ৮টায় সরে যায় — রাত ৩টার notification কেউ পড়ে না, আর তখন কিছু করারও নেই।

**Siri** — *"What is my Bidyut balance"*, আর running-cost intent।

---

## Verification

Protocol আর parser আসল account-এর (12345678) live portal response-এর বিরুদ্ধে যাচাই করা, 19 Nov 2026-এ:

| | |
|---|---|
| Form fields | `_token`, `cust_no`, `submit` — কোনো captcha নেই |
| `con_info_div` | ১৮টা input, ১৫টা label; index 14 = "অবশিষ্ট ব্যালেন্স (টাকা)" |
| Recharge rows | ৩৮টা, `<a class="consumerRechargeData">` tag-এ ২১টা `data-*` attribute |
| Status parsing | ৩৪ Success / ৪ Failed, কোনো empty নেই |
| Monthly columns | ১৩টার সবগুলো header-match-এ resolve হয় |
| Date format | `08-NOV-2026 12:59 PM` — `dd-MMM-yyyy h:mm a` |

যাচাই করতে গিয়ে তিনটা bug ধরা পড়ে ও ঠিক করা হয়েছে: date format parse হচ্ছিল না (সব recharge বাদ পড়ত), monthly-তে ভুল "টাকা" column নেওয়া হচ্ছিল (রিচার্জ, খরচ নয়), আর Bengali Unicode normalization-এর কারণে `রেয়াত` column আর "তথ্য পাওয়া যায়নি" check fail করছিল।

---

## জানা সীমাবদ্ধতা

- Portal HTML scraping — NESCO layout বদলালে `NescoParser` update করতে হবে।
- Background refresh-এর সময় iOS ঠিক করে, আমরা না। ৪ ঘণ্টা চাওয়া হয়, কিন্তু iOS কম-বেশি করতে পারে। Forecast এতে ভাঙে না, কারণ সেটা elapsed time ধরে হিসাব করে।
- Portal balance সাথে সাথে update হয় না, তাই একই reading বারবার এলে app সেটা skip করে — না হলে burn rate ভুল করে শূন্যের দিকে নেমে যেত।
- Customer number লাগবে, meter number না। Customer number ৫–১৪ digit, meter-এ আর recharge receipt-এ লেখা থাকে।
