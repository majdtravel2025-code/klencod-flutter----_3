# مطاعم مدينتي — تطبيق Flutter أصلي

هذا المجلد `android_app/` يحتوي تطبيق Android أصلياً بواجهات Flutter/Dart (ليس WebView).

## وظائف تطبيق الزبون
- عرض الصفحة الرئيسية والأصناف الأكثر طلباً.
- عرض قائمة المطعم والأقسام والبحث.
- سلة مشتريات وتعديل الكميات.
- تسجيل الدخول وإنشاء حساب برقم الجوال.
- طلب استلام من المطعم أو توصيل مع العنوان والملاحظات.
- متابعة الطلبات وتحديث حالتها تلقائياً كل 15 ثانية.
- إلغاء الطلب ما دام جديداً.
- صفحة الحساب وتسجيل الخروج.

لوحة المدير الحالية تبقى متاحة من المتصفح على `/manager` وتستخدم نفس خادم الطلبات.

## 1) نشر الخادم
من المجلد الرئيسي `madinati-app/` انشر خادم Node.js على استضافة تدعم Node.js 18+، ثم اضبط:
- `MANAGER_USER`: اسم مدير مخصص.
- `MANAGER_PASS`: كلمة مرور قوية.
- `APP_SECRET`: سر عشوائي طويل وثابت.
- `DATA_DIR`: مسار تخزين دائم إذا كانت الاستضافة تتطلب ذلك.

شغّل `npm start`، وفعّل HTTPS، واختبر:
- `https://YOUR-DOMAIN/api/health`
- `https://YOUR-DOMAIN/api/menu`

ينبغي أن يرجع مسار الصحة JSON يتضمن `ok: true`. احتفظ بتخزين دائم ونسخ احتياطية لملف قاعدة البيانات. لا تستخدم كلمة مرور المدير التجريبية على الإنترنت.

## 2) ربط تطبيق Flutter بالخادم
افتح `android_app/lib/app_config.dart`، واستبدل:
`https://YOUR-DOMAIN-HERE`
برابط الخادم الفعلي، مثال:
`https://madinati.example.com`

يجب أن يكون الرابط HTTPS ومن دون `/` في النهاية. التطبيق يستخدم API الخادم مباشرة، ولا يحوي قاعدة بيانات الطلبات داخله.

## 3) البناء في Klencod IDE
1. فك ضغط الحزمة.
2. افتح مجلد `android_app` نفسه كمشروع Flutter في Klencod IDE.
3. اسمح بتنزيل Flutter packages عند أول فتح (`http` و`shared_preferences`).
4. تأكد من وضع رابط الخادم في `lib/app_config.dart`.
5. اختر Build APK لإنتاج ملف تثبيت تجريبي أو Build App Bundle لإنتاج AAB للنشر على Google Play.
6. اختبر التسجيل والطلب ومتابعة الحالة على جهاز فعلي قبل النشر.

## البناء من سطر أوامر Flutter
داخل `android_app/`:

```bash
flutter pub get
flutter build apk --release --dart-define=APP_URL=https://your-domain.example
```

ولملف Google Play:

```bash
flutter build appbundle --release --dart-define=APP_URL=https://your-domain.example
```

المخرجات:
- APK: `build/app/outputs/flutter-apk/app-release.apk`
- AAB: `build/app/outputs/bundle/release/app-release.aab`

يمكن أيضاً وضع الرابط مباشرة في `app_config.dart` بدلاً من `--dart-define`.

## إعداد Android
- Application ID: `com.madinati.mobile`
- Version: `1.0.0+1`
- minSdk: 24
- targetSdk: 36
- INTERNET permission مفعّل
- أيقونة التطبيق مضافة من شعار مدينتي

قبل النشر العام، أنشئ مفتاح توقيع Release خاصاً بك واحفظه بأمان، واضبط سياسة الخصوصية وبيانات صفحة المتجر. لا تشارك ملف keystore أو كلمات مروره.

## ملاحظات
- هذا تطبيق زبائن Flutter أصلي. لوحة المدير لا تزال لوحة ويب مستقلة.
- لا يمكن اختبار اتصال الطلبات الحقيقية حتى يتم توفير رابط خادم منشور صالح.
- لا يمكن توليد APK/AAB في بيئة إعداد هذه الحزمة لعدم توفر Flutter SDK هنا؛ استخدم Klencod IDE أو بيئة Flutter لإنتاج الملف.
