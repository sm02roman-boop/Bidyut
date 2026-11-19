# iPhone-এ তোলার ধাপগুলো

আপনার **MacBook Air 2020 (Intel)** ধরে লেখা।

---

## আগে দুটো কথা

**আপনার Mac macOS Sequoia-তেই থামবে.** macOS Tahoe ২৬ Intel Mac-এর শেষ সংস্করণ, কিন্তু সেটা মাত্র চারটা মডেল পায় — MacBook Pro ১৬" (২০১৯), MacBook Pro ১৩" (২০২০, চার Thunderbolt পোর্ট), iMac ২৭" (২০২০) আর Mac Pro (২০১৯)। MacBook Air তাতে নেই।

সমস্যা না — এই project iOS 17 টার্গেট করে, Xcode 15+ হলেই চলে, আর Sequoia-তে তার চেয়ে নতুন Xcode পাবেন।

**Free Apple ID দিয়ে App Group সাইন করা যায় না.** আর App Group ছাড়া widget আর Live Activity অ্যাপের ডেটা পড়তে পারে না। তাই দুটো আলাদা path:

| | Free Apple ID | $99/বছর Developer Program |
|---|---|---|
| মূল অ্যাপ | ✅ | ✅ |
| Notification, Siri | ✅ | ✅ |
| Home/Lock Screen widget | ❌ | ✅ |
| Live Activity | ❌ | ✅ |
| কত দিন চলবে | **৭ দিন**, পরে আবার build | ১ বছর |

শুরু করুন free দিয়ে। কাজের মনে হলে তখন $99 দিলে একই কোড পুরোটা চলবে, শুধু `project.yml` ব্যবহার করবেন।

---

---

## Sideloadly দিয়ে করতে চাইলে

**Sideloadly কোড compile করে না** — ও তৈরি `.ipa` নিয়ে আপনার Apple ID দিয়ে sign করে ঢোকায়। তাই Mac + Xcode দিয়ে `.ipa` বানাতেই হবে। Xcode installও করতেই হবে (ধাপ ১ আর ২ লাগবেই)।

তবু Sideloadly-র দুটো সুবিধা আছে:

- **Auto-refresh** — ৭ দিন পরপর নিজে re-sign করে। Xcode-এ হাতে ⌘R চাপতে হয়।
- **Widget কাজ করতে পারে** — Sideloadly App Group-কে team-unique নামে remap করে দেয়। অ্যাপ সেই আসল নামটা `embedded.mobileprovision` থেকে পড়ে নেয়, তাই অ্যাপ আর widget একই জায়গায় পৌঁছায়। Xcode-এর personal team এটা পারে না।

```bash
cd ~/Downloads/Bidyut
xcodegen generate          # পুরোটা, project-free.yml নয়
./build-ipa.sh
```

`build/Bidyut.ipa` তৈরি হবে। Sideloadly খুলে ওটা drag করুন, Apple ID দিন, **Start**। Settings-এ auto-refresh চালু করে দিবেন।

**Sideloadly-তে `project-free.yml` ব্যবহার করবেন না** — ওটা widget বাদ দিয়ে দেয়, অথচ Sideloadly-তে widget চলতে পারে।

এখানেও ৭ দিনের মেয়াদ আর ৩টা অ্যাপের সীমা থাকবে, ওগুলো Apple-এর, টুলের না।

---

## ১. Xcode

Mac App Store → **Xcode** খুঁজে install। আপনার macOS-এ যেটা চলে সেটাই দিবে। ১৫–২০ GB, সময় লাগবে।

তারপর একবার খুলে license accept করুন, আর Terminal-এ:

```bash
xcode-select --install
```

## ২. XcodeGen

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install xcodegen
```

Homebrew আগে থেকে থাকলে শুধু দ্বিতীয় লাইনটা।

## ৩. Project তৈরি

zip খুলে, `Bidyut` ফোল্ডারে ঢুকে:

```bash
cd ~/Downloads/Bidyut
xcodegen generate --spec project-free.yml   # free Apple ID
# অথব়া: xcodegen generate                   # paid account
open Bidyut.xcodeproj
```

## ৪. Bundle ID আর Team

Xcode-এ বাম দিকে **Bidyut** project → **Signing & Capabilities**:

1. **Team** → "Add an Account…" → আপনার Apple ID দিন → তারপর `আপনার নাম (Personal Team)` বেছে নিন
2. **Bundle Identifier** বদলান — `com.codeyo.bidyut` হয়তো নিতে দিবে না। নিজের মতো দিন, যেমন `com.shihan.bidyut`

`Signing Certificate: Apple Development` দেখালে ঠিক আছে।

## ৫. iPhone যুক্ত করা

1. কেবল দিয়ে iPhone লাগান, ফোনে **Trust** চাপুন
2. iPhone-এ **Settings → Privacy & Security → Developer Mode** চালু করুন, ফোন restart হবে
3. Xcode-এর উপরে device তালিকা থেকে আপনার iPhone বেছে নিন
4. **⌘R**

প্রথমবার অ্যাপ খুলতে গেলে "Untrusted Developer" বলবে। iPhone-এ **Settings → General → VPN & Device Management → আপনার Apple ID → Trust** করুন।

---

## ৬. প্রথম রান

অ্যাপ খুললে গ্রাহক নম্বর চাইবে — **12345678**।

**VPN বন্ধ রাখুন।** NESCO portal শুধু বাংলাদেশি IP-তে সাড়া দেয়, নাহলে 403।

ঠিকঠাক হলে নাম, ঠিকানা আর balance দেখিয়ে confirm চাইবে।

---

## কিছু ভাঙলে

**`xcodegen: command not found`** → `brew install xcodegen` হয়নি, বা Terminal নতুন করে খুলতে হবে।

**`Failed to register bundle identifier`** → ওই ID কেউ নিয়ে রেখেছে। bundle ID বদলান।

**`doesn't support the App Groups capability`** → `project.yml` দিয়ে generate করেছেন। `project-free.yml` দিয়ে আবার করুন।

**`Unable to install… profile has expired`** → free account-এর ৭ দিন শেষ। Xcode খুলে আবার ⌘R, আর কিছু লাগবে না।

**Portal-এ 403** → VPN চালু আছে, অথবা wifi-র DNS বাইরে যাচ্ছে। মোবাইল ডেটায় চেষ্টা করুন।

**Build error** → পুরো error টা কপি করে পাঠাবেন। SwiftData আর WidgetKit-এর অনেক ভুল শুধু compiler-ই ধরে, আমি এখান থেকে compile করতে পারি না।

---

## অ্যাপ ছাড়া: server

Xcode-এর ঝামেলায় না গিয়েও আজ থেকেই ডেটা জমানো শুরু করতে পারেন:

```bash
cd Bidyut/server
cp config.example.json config.json
# meters আর token বসান
node index.js
```

Node 18+ লাগে, আর কিছু না। এটা চললে ঘণ্টাভিত্তিক ইতিহাস জমতে থাকবে — অ্যাপ তৈরি হওয়ার আগেই। বিস্তারিত `server/README.md`-তে।
