class AppConfig {
  // استبدل هذا الرابط بعنوان خادم مدينتي المنشور مع HTTPS.
  static const String serverUrl = String.fromEnvironment(
    'APP_URL',
    defaultValue: 'https://YOUR-DOMAIN-HERE',
  );
  static const String currency = 'ر.ي';
  static const String mapsUrl = 'https://maps.app.goo.gl/9BPDW8GanTAxmeVu9';
}
