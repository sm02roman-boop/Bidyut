# Bidyut poller

NESCO portal প্রতি ১৫ মিনিটে পড়ে, আর যে ইতিহাসটা portal নিজে রাখে না সেটা জমায় — **ঘণ্টাভিত্তিক usage curve**।

ফোন দিনের বেশিরভাগ সময় ঘুমিয়ে থাকে, তাই অ্যাপ নিজে এটা পারে না। এই process-টার থাকার কারণই সেটা।

**Zero dependency.** Node 18+ লাগে, আর কিছু না।

---

## চালু করা

```bash
cp config.example.json config.json
# config.json খুলে meters আর token বসান
node index.js
```

`token` অবশ্যই বদলাবেন — এই API আপনার বাসার বিদ্যুতের তথ্য দেয়, খোলা রাখা যাবে না।

### VPS-এ (systemd)

```bash
sudo useradd -r -s /bin/false bidyut
sudo mkdir -p /opt/bidyut && sudo cp -r server /opt/bidyut/
sudo chown -R bidyut:bidyut /opt/bidyut
sudo cp /opt/bidyut/server/bidyut.service /etc/systemd/system/
sudo systemctl enable --now bidyut
sudo journalctl -u bidyut -f
```

**VPS বাংলাদেশে হতে হবে.** Portal শুধু বাংলাদেশি IP-তে সাড়া দেয়, বাইরে থেকে 403। দেশি হোস্টিং (Dhaka Colo, ExonHost, IS Pros) বা বাসার একটা Raspberry Pi — দুটোই চলে।

---

## API

সব endpoint-এ `Authorization: Bearer <token>` লাগে, `/health` ছাড়া।

| | |
|---|---|
| `GET /health` | poller বেঁচে আছে কিনা, শেষ কবে পড়েছে |
| `GET /api/meter/:customerNo` | এখনকার balance, info, recharge, monthly |
| `GET /api/meter/:customerNo/hourly?hours=168` | ঘণ্টাভিত্তিক খরচ + দিনের গড় profile |
| `GET /api/meter/:customerNo/readings?days=30` | কাঁচা balance reading |

```bash
curl -H "Authorization: Bearer $TOKEN" localhost:8099/api/meter/12345678/hourly
```

---

## ঘণ্টার হিসাব কীভাবে হয়

Balance শুধু ব্যবহারে কমে আর রিচার্জে বাড়ে। তাই দুটো reading-এর মাঝে খরচ:

```
consumed = আগের balance + মাঝে credited − এখনকার balance
```

`credited` মানে রিচার্জের **বিদ্যুৎ অংশ**, মোট টাকা নয় — NESCO মিটার ভাড়া, ডিমান্ড চার্জ আর ভ্যাট আগে কেটে নেয়।

তারপর ওই খরচটা interval যতগুলো ঘণ্টা ছুঁয়েছে, তাদের মধ্যে ভাগ করে দেওয়া হয় — প্রতিটা ঘণ্টার যতটুকু অংশ ঢেকেছে সেই অনুপাতে। ১৫ মিনিটের poll এটাকে যথেষ্ট সূক্ষ্ম করে।

**যা বাদ পড়ে:** ব্যাখ্যাহীনভাবে balance বাড়লে (রিচার্জ মিস হয়েছে), আর ৬ ঘণ্টার বেশি ফাঁক — দুটোর কোনোটাই পরিমাপ নয়, ধরে রাখলে curve মিথ্যা বলবে।

---

## তথ্য যেভাবে রাখা

`data/<customerNo>.readings.jsonl` — প্রতি লাইনে একটা reading। ইচ্ছে করেই append-only: লেখা অর্ধেক হলে সর্বোচ্চ শেষ reading যায়, পুরো ইতিহাস না। `tail`, `grep`, `wc -l` সব কাজ করে, যেটা রাত ২টায় VPS-এ কিছু ভাঙলে দরকার হয়।

একটা মিটারে বছরে ১০ MB-ও হয় না, তাই database-এর দরকার নেই।

একই balance আবার এলে লেখা হয় না — না হলে ইতিহাস ফুলে যেত আর burn rate শূন্যের দিকে নামত।

---

## Test

```bash
node test.js
```

Parser গুলো portal-এর আসল গড়নের সাথে বাঁধা, আর hourly aggregation তার অঙ্কের সাথে। যে ভুলগুলো crash না করে চুপচাপ ভুল সংখ্যা দেয়, সেগুলোই এখানে ধরা।

---

## সীমাবদ্ধতা

Portal HTML scraping — NESCO layout বদলালে `nesco.js` ঠিক করতে হবে, আর কিছু না।

Portal নিজে balance সাথে সাথে update করে না, তাই ১৫ মিনিটের চেয়ে ঘন poll করে লাভ নেই — একই সংখ্যা ফিরবে, শুধু সরকারি সার্ভারে চাপ বাড়বে। `pollMinutes`-এর সর্বনিম্ন ৫।
