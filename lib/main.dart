import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = MadinatiState();
  await app.initialize();
  runApp(MadinatiApp(state: app));
}

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, [this.status]);
  @override
  String toString() => message;
}

class MadinatiApi {
  static String get base => AppConfig.serverUrl.replaceAll(RegExp(r'/$'), '');
  static bool get configured =>
      Uri.tryParse(base)?.hasAuthority == true &&
      Uri.parse(base).scheme == 'https' &&
      !base.contains('YOUR-DOMAIN-HERE');

  static Future<dynamic> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    if (!configured) {
      throw ApiException('أضف رابط الخادم HTTPS في lib/app_config.dart أولاً.');
    }
    final uri = Uri.parse('$base/api$path');
    final headers = <String, String>{'content-type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    late http.Response response;
    try {
      switch (method) {
        case 'GET':
          response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
          break;
        case 'POST':
          response = await http.post(uri, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 25));
          break;
        default:
          throw ApiException('طريقة اتصال غير مدعومة');
      }
    } on TimeoutException {
      throw ApiException('انتهت مهلة الاتصال بالخادم. حاول مرة أخرى.');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException('تعذّر الاتصال بالخادم. تحقق من الإنترنت.');
    }
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      data = <String, dynamic>{};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        data is Map ? (data['message'] ?? 'حدث خطأ في الخادم').toString() : 'حدث خطأ في الخادم',
        response.statusCode,
      );
    }
    return data;
  }

  static Future<Map<String, dynamic>> menu() async =>
      Map<String, dynamic>.from(await request('GET', '/menu') as Map);

  static Future<Map<String, dynamic>> login(String phone, String password) async =>
      Map<String, dynamic>.from(await request('POST', '/auth/login',
          body: {'login': phone, 'password': password}) as Map);

  static Future<Map<String, dynamic>> register(String name, String phone, String password) async =>
      Map<String, dynamic>.from(await request('POST', '/auth/register',
          body: {'name': name, 'phone': phone, 'password': password}) as Map);

  static Future<Map<String, dynamic>> me(String token) async =>
      Map<String, dynamic>.from(await request('GET', '/me', token: token) as Map);

  static Future<Map<String, dynamic>> createOrder(
    String token, String type, String address, String notes,
    List<Map<String, dynamic>> items,
  ) async =>
      Map<String, dynamic>.from(await request('POST', '/orders', token: token,
          body: {'type': type, 'address': address, 'notes': notes, 'items': items}) as Map);

  static Future<List<dynamic>> orders(String token) async {
    final data = await request('GET', '/orders/mine', token: token) as Map;
    return List<dynamic>.from(data['orders'] ?? []);
  }

  static Future<void> cancelOrder(String token, dynamic id) async {
    await request('POST', '/orders/$id/cancel', token: token);
  }
}

class MadinatiState extends ChangeNotifier {
  String? token;
  Map<String, dynamic>? user;
  Map<String, dynamic>? menuData;
  final Map<String, int> cart = {};
  bool busy = false;
  String? lastError;

  List<dynamic> get items => List<dynamic>.from(menuData?['items'] ?? []);
  List<dynamic> get categories => List<dynamic>.from(menuData?['categories'] ?? []);
  Map<String, dynamic> get settings =>
      Map<String, dynamic>.from(menuData?['settings'] ?? {});
  bool get loggedIn => token != null && user != null;
  int get cartCount => cart.values.fold(0, (a, b) => a + b);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString('madinati_token');
    try {
      await refreshMenu();
      if (token != null) {
        final data = await MadinatiApi.me(token!);
        user = Map<String, dynamic>.from(data['user']);
        if (user?['role'] != 'customer') await logout();
      }
    } catch (e) {
      lastError = e.toString();
    }
  }

  Future<void> refreshMenu() async {
    menuData = await MadinatiApi.menu();
    final valid = items.map((e) => e['id'].toString()).toSet();
    cart.removeWhere((key, value) => !valid.contains(key));
    notifyListeners();
  }

  Future<void> saveToken(String value) async {
    token = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('madinati_token', value);
  }

  Future<void> login(String phone, String password, {String? name}) async {
    busy = true; notifyListeners();
    try {
      final result = name == null
          ? await MadinatiApi.login(phone, password)
          : await MadinatiApi.register(name, phone, password);
      final u = Map<String, dynamic>.from(result['user']);
      if (u['role'] != 'customer') throw ApiException('هذا حساب المدير. استخدم لوحة المدير.');
      await saveToken(result['token'].toString());
      user = u;
      lastError = null;
    } finally {
      busy = false; notifyListeners();
    }
  }

  Future<void> logout() async {
    token = null; user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('madinati_token');
    notifyListeners();
  }

  void add(String id) { cart[id] = (cart[id] ?? 0) + 1; notifyListeners(); }
  void remove(String id) {
    final n = (cart[id] ?? 0) - 1;
    if (n <= 0) { cart.remove(id); } else { cart[id] = n; }
    notifyListeners();
  }
  void clearCart() { cart.clear(); notifyListeners(); }

  int price(dynamic item) => (item['price'] as num).round();
  int total() {
    var sum = 0;
    for (final item in items) {
      sum += price(item) * (cart[item['id']] ?? 0);
    }
    return sum;
  }
  List<Map<String, dynamic>> orderItems() => cart.entries
      .map((e) => {'id': e.key, 'qty': e.value})
      .toList();
}

class MadinatiApp extends StatelessWidget {
  final MadinatiState state;
  const MadinatiApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'مطاعم مدينتي',
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8F2F08),
            primary: const Color(0xFF8F2F08),
            secondary: const Color(0xFFD89B35),
            surface: const Color(0xFFFFFBF7),
          ),
          scaffoldBackgroundColor: const Color(0xFFFFFBF7),
          fontFamily: 'Roboto',
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFFFFBF7),
            foregroundColor: Color(0xFF34251F),
            centerTitle: true,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE8DED7)),
            ),
          ),
        ),
        home: MainShell(state: state),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  final MadinatiState state;
  const MainShell({super.key, required this.state});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (!MadinatiApi.configured) {
      return Scaffold(
        appBar: AppBar(title: const Text('مطاعم مدينتي')),
        body: const SetupNotice(),
      );
    }
    if (s.menuData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('مطاعم مدينتي')),
        body: Center(child: s.lastError == null
            ? const CircularProgressIndicator()
            : ErrorPanel(message: s.lastError!, onRetry: () async {
                try { await s.refreshMenu(); } catch (e) { s.lastError = e.toString(); s.notifyListeners(); }
              })),
      );
    }
    final pages = [
      HomePage(state: s, onMenu: () => setState(() => tab = 1)),
      MenuPage(state: s),
      CartPage(state: s, onLogin: () => _openLogin()),
      OrdersPage(state: s, onLogin: () => _openLogin()),
      AccountPage(state: s, onLogin: () => _openLogin()),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('مطاعم مدينتي', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'تحديث القائمة',
            onPressed: () async { try { await s.refreshMenu(); } catch (e) { _snack(e.toString()); } },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'الرئيسية'),
          const NavigationDestination(icon: Icon(Icons.restaurant_menu), label: 'القائمة'),
          NavigationDestination(
            icon: Badge(isLabelVisible: s.cartCount > 0, label: Text('${s.cartCount}'), child: const Icon(Icons.shopping_basket_outlined)),
            label: 'السلة',
          ),
          const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'طلباتي'),
          const NavigationDestination(icon: Icon(Icons.person_outline), label: 'حسابي'),
        ],
      ),
    );
  }

  Future<void> _openLogin() async {
    if (widget.state.loggedIn) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AuthPage(state: widget.state)),
    );
    if (ok == true && mounted) setState(() {});
  }
  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class SetupNotice extends StatelessWidget {
  const SetupNotice({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.settings_ethernet, size: 64, color: Color(0xFF8F2F08)),
        const SizedBox(height: 18),
        const Text('يلزم ربط التطبيق بالخادم', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        const Text('افتح lib/app_config.dart وضع رابط خادم مدينتي المنشور باستخدام HTTPS في serverUrl، ثم أعد بناء التطبيق.', textAlign: TextAlign.center),
      ]),
    ),
  );
}

class ErrorPanel extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorPanel({super.key, required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.cloud_off, size: 54, color: Colors.redAccent),
      const SizedBox(height: 12),
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      FilledButton(onPressed: onRetry, child: const Text('إعادة المحاولة')),
    ]),
  ));
}

class HomePage extends StatelessWidget {
  final MadinatiState state;
  final VoidCallback onMenu;
  const HomePage({super.key, required this.state, required this.onMenu});
  @override
  Widget build(BuildContext context) {
    final popular = state.items.where((i) => i['pop'] == true && i['available'] == true).take(8).toList();
    final closed = state.settings['acceptingOrders'] == false;
    return RefreshIndicator(
      onRefresh: state.refreshMenu,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (closed) const _ClosedBanner(),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: const LinearGradient(
              colors: [Color(0xFF8F2F08), Color(0xFFB85A20)],
              begin: Alignment.topRight, end: Alignment.bottomLeft,
            ),
          ),
          child: Column(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset('assets/logo.png', height: 118, width: 118, fit: BoxFit.cover),
            ),
            const SizedBox(height: 16),
            const Text('من مدينتنا إلى مائدتك', textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text('اختر وجبتك، وسجّل طلبك، ونحن نجهّزه لك.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFFD88B), foregroundColor: const Color(0xFF54270D)),
              onPressed: onMenu, child: const Text('تصفّح القائمة'),
            ),
          ]),
        ),
        const SizedBox(height: 22),
        const SectionTitle('الأكثر طلباً'),
        if (popular.isEmpty) const Text('تصفح قائمة المطعم واختر وجبتك.')
        else ...popular.map((i) => ItemTile(state: state, item: i)),
        const SizedBox(height: 12),
        RestaurantInfo(settings: state.settings),
      ]),
    );
  }
}

class _ClosedBanner extends StatelessWidget {
  const _ClosedBanner();
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(12)),
    child: const Row(children: [Icon(Icons.info_outline, color: Colors.red), SizedBox(width: 8), Text('المطعم لا يستقبل الطلبات حالياً')]),
  );
}

class SectionTitle extends StatelessWidget {
  final String title;
  const SectionTitle(this.title, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10, top: 8),
    child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
  );
}

class MenuPage extends StatefulWidget {
  final MadinatiState state;
  const MenuPage({super.key, required this.state});
  @override
  State<MenuPage> createState() => _MenuPageState();
}
class _MenuPageState extends State<MenuPage> {
  String? category;
  String query = '';
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final cats = s.categories;
    final selected = category ?? (cats.isNotEmpty ? cats.first['id'].toString() : '');
    final filtered = s.items.where((i) =>
      (selected.isEmpty || i['cat'] == selected) &&
      i['name'].toString().toLowerCase().contains(query.toLowerCase())).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث عن صنف'),
          onChanged: (v) => setState(() => query = v),
        ),
      ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12),
          children: cats.map((c) {
            final id = c['id'].toString();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(c['name'].toString()),
                selected: selected == id,
                onSelected: (_) => setState(() => category = id),
              ),
            );
          }).toList(),
        ),
      ),
      Expanded(child: filtered.isEmpty
        ? const Center(child: Text('لا توجد أصناف مطابقة.'))
        : ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            itemBuilder: (_, i) => ItemTile(state: s, item: filtered[i]),
          )),
    ]);
  }
}

class ItemTile extends StatelessWidget {
  final MadinatiState state;
  final dynamic item;
  const ItemTile({super.key, required this.state, required this.item});
  @override
  Widget build(BuildContext context) {
    final id = item['id'].toString();
    final qty = state.cart[id] ?? 0;
    final available = item['available'] != false;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17), side: const BorderSide(color: Color(0xFFECE2DA))),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(children: [
          Container(
            width: 58, height: 58,
            decoration: BoxDecoration(color: const Color(0xFFFFF0DF), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.restaurant, color: Color(0xFF8F2F08), size: 30),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item['name'].toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            if ((item['desc'] ?? '').toString().isNotEmpty)
              Text(item['desc'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
            const SizedBox(height: 5),
            Text('${_money((item['price'] as num).round())} ${AppConfig.currency}',
              style: const TextStyle(color: Color(0xFF8F2F08), fontWeight: FontWeight.w900)),
            if (!available) const Text('غير متوفر حالياً', style: TextStyle(color: Colors.red, fontSize: 12)),
          ])),
          const SizedBox(width: 8),
          if (available) qty == 0
            IconButton.filledTonal(onPressed: () => state.add(id), icon: const Icon(Icons.add))
          else
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(onPressed: () => state.remove(id), icon: const Icon(Icons.remove_circle_outline)),
              Text('$qty', style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton(onPressed: () => state.add(id), icon: const Icon(Icons.add_circle_outline)),
            ]),
        ]),
      ),
    );
  }
}

class CartPage extends StatefulWidget {
  final MadinatiState state;
  final VoidCallback onLogin;
  const CartPage({super.key, required this.state, required this.onLogin});
  @override
  State<CartPage> createState() => _CartPageState();
}
class _CartPageState extends State<CartPage> {
  String type = 'pickup';
  final address = TextEditingController();
  final notes = TextEditingController();
  bool sending = false;
  @override
  void dispose() { address.dispose(); notes.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final chosen = s.items.where((i) => (s.cart[i['id']] ?? 0) > 0).toList();
    if (chosen.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.shopping_basket_outlined, size: 64, color: Color(0xFFB7A69B)),
          SizedBox(height: 12),
          Text('سلتك فارغة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          Text('أضف بعض الوجبات من القائمة.'),
        ]),
      ));
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      const SectionTitle('سلة المشتريات'),
      ...chosen.map((i) {
        final id = i['id'].toString();
        final qty = s.cart[id] ?? 0;
        final line = ((i['price'] as num).round()) * qty;
        return Card(
          elevation: 0,
          child: ListTile(
            title: Text(i['name'].toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${_money(line)} ${AppConfig.currency}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(onPressed: () => s.remove(id), icon: const Icon(Icons.remove_circle_outline)),
              Text('$qty'),
              IconButton(onPressed: () => s.add(id), icon: const Icon(Icons.add_circle_outline)),
            ]),
          ),
        );
      }),
      Card(
        elevation: 0,
        child: Padding(padding: const EdgeInsets.all(16), child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [const Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Text('${_money(s.total())} ${AppConfig.currency}', style: const TextStyle(fontSize: 20, color: Color(0xFF8F2F08), fontWeight: FontWeight.w900))],
        )),
      ),
      const SectionTitle('تفاصيل الطلب'),
      if (!s.loggedIn)
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          const Text('سجّل الدخول أو أنشئ حساباً لإرسال الطلب.'),
          const SizedBox(height: 10),
          FilledButton(onPressed: widget.onLogin, child: const Text('تسجيل الدخول')),
        ])))
      else ...[
        Text('الطلب باسم ${s.user?['name']} · ${s.user?['login']}'),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'pickup', label: Text('استلام من المطعم'), icon: Icon(Icons.storefront)),
            ButtonSegment(value: 'delivery', label: Text('توصيل'), icon: Icon(Icons.delivery_dining)),
          ],
          selected: {type},
          onSelectionChanged: (v) => setState(() => type = v.first),
        ),
        if (type == 'delivery') ...[
          const SizedBox(height: 12),
          TextField(controller: address, decoration: const InputDecoration(labelText: 'عنوان التوصيل', hintText: 'الحي، الشارع، أقرب معلم')),
        ],
        const SizedBox(height: 12),
        TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)', hintText: 'مثال: بدون بصل')),
        const SizedBox(height: 16),
        if (s.settings['acceptingOrders'] == false)
          const Text('المطعم لا يستقبل الطلبات حالياً.', style: TextStyle(color: Colors.red)),
        FilledButton.icon(
          onPressed: sending || s.settings['acceptingOrders'] == false ? null : _submit,
          icon: sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
          label: const Text('إرسال الطلب'),
        ),
      ],
    ]);
  }

  Future<void> _submit() async {
    final s = widget.state;
    if (type == 'delivery' && address.text.trim().length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اكتب عنوان التوصيل.')));
      return;
    }
    setState(() => sending = true);
    try {
      final order = await MadinatiApi.createOrder(
        s.token!, type, address.text.trim(), notes.text.trim(), s.orderItems(),
      );
      s.clearCart();
      if (!mounted) return;
      showDialog(context: context, builder: (_) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 44),
        title: const Text('تم إرسال طلبك'),
        content: Text('رقم الطلب #${order['id']}\nالإجمالي ${_money((order['total'] as num).round())} ${AppConfig.currency}'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('حسناً'))],
      ));
    } catch (e) {
      if (e is ApiException && e.status == 401) await s.logout();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}

class AuthPage extends StatefulWidget {
  final MadinatiState state;
  const AuthPage({super.key, required this.state});
  @override
  State<AuthPage> createState() => _AuthPageState();
}
class _AuthPageState extends State<AuthPage> {
  bool registering = false, busy = false, obscure = true;
  final name = TextEditingController();
  final phone = TextEditingController();
  final password = TextEditingController();
  @override
  void dispose() { name.dispose(); phone.dispose(); password.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('حسابك في مطاعم مدينتي')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Center(child: Image.asset('assets/logo.png', width: 112, height: 112)),
      const SizedBox(height: 12),
      Text(registering ? 'إنشاء حساب جديد' : 'مرحباً بعودتك', textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900)),
      const SizedBox(height: 18),
      if (registering) ...[
        TextField(controller: name, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'الاسم')),
        const SizedBox(height: 12),
      ],
      TextField(controller: phone, keyboardType: TextInputType.phone, textDirection: TextDirection.ltr,
        decoration: const InputDecoration(labelText: 'رقم الجوال', hintText: '7xxxxxxxx')),
      const SizedBox(height: 12),
      TextField(controller: password, obscureText: obscure,
        decoration: InputDecoration(labelText: 'كلمة المرور', suffixIcon: IconButton(
          onPressed: () => setState(() => obscure = !obscure),
          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
        ))),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: busy ? null : _submit,
        child: busy ? const CircularProgressIndicator() : Text(registering ? 'إنشاء الحساب' : 'تسجيل الدخول'),
      ),
      TextButton(
        onPressed: busy ? null : () => setState(() => registering = !registering),
        child: Text(registering ? 'لدي حساب بالفعل — تسجيل الدخول' : 'ليس لدي حساب — إنشاء حساب جديد'),
      ),
    ]),
  );

  Future<void> _submit() async {
    if (registering && name.text.trim().length < 2) {
      _error('اكتب اسمك (حرفان على الأقل)'); return;
    }
    if (phone.text.trim().length < 7 || password.text.length < 6) {
      _error('تحقق من رقم الجوال وكلمة المرور (6 أحرف على الأقل).'); return;
    }
    setState(() => busy = true);
    try {
      await widget.state.login(phone.text.trim(), password.text, name: registering ? name.text.trim() : null);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _error(e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  void _error(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

class OrdersPage extends StatefulWidget {
  final MadinatiState state;
  final VoidCallback onLogin;
  const OrdersPage({super.key, required this.state, required this.onLogin});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}
class _OrdersPageState extends State<OrdersPage> {
  List<dynamic> orders = [];
  bool loading = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    if (widget.state.loggedIn) {
      _load();
      timer = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
    }
  }
  @override
  void didUpdateWidget(covariant OrdersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.loggedIn && timer == null) {
      _load();
      timer = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
    } else if (!widget.state.loggedIn) {
      timer?.cancel();
      timer = null;
      orders = [];
    }
  }
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (!widget.state.loggedIn) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.receipt_long, size: 58, color: Color(0xFFB7A69B)),
      const SizedBox(height: 12),
      const Text('سجّل الدخول لمتابعة طلباتك.'),
      const SizedBox(height: 10),
      FilledButton(onPressed: widget.onLogin, child: const Text('تسجيل الدخول')),
    ]));
    return RefreshIndicator(
      onRefresh: _load,
      child: loading && orders.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : error != null && orders.isEmpty
          ? ErrorPanel(message: error!, onRetry: _load)
          : orders.isEmpty
            ? ListView(children: const [SizedBox(height: 150), Center(child: Text('لا توجد طلبات بعد.'))])
            : ListView.builder(
                padding: const EdgeInsets.all(14), itemCount: orders.length,
                itemBuilder: (_, i) => _orderCard(orders[i]),
              ),
    );
  }
  Widget _orderCard(dynamic o) {
    final status = _status(o['status'].toString());
    final lines = List<dynamic>.from(o['items'] ?? []);
    return Card(
      elevation: 0, margin: const EdgeInsets.only(bottom: 12),
      child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('طلب #${o['id']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
          Chip(label: Text(status.$1), backgroundColor: status.$2),
        ]),
        Text('${o['type'] == 'delivery' ? 'توصيل' : 'استلام من المطعم'}${(o['address'] ?? '').toString().isEmpty ? '' : ' · ${o['address']}'}',
          style: TextStyle(color: Colors.grey.shade700)),
        const Divider(),
        ...lines.map((l) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${l['qty']} × ${l['name']}'),
            Text(_money(((l['qty'] as num) * (l['price'] as num)).round())),
          ]),
        )),
        const Divider(),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('${_money((o['total'] as num).round())} ${AppConfig.currency}', style: const TextStyle(fontWeight: FontWeight.w900)),
        ]),
        if (o['status'] == 'new') Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: () => _cancel(o['id']),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('إلغاء الطلب'),
          ),
        ),
      ])),
    );
  }
  Future<void> _load({bool silent = false}) async {
    if (!widget.state.loggedIn) return;
    if (!silent && mounted) setState(() { loading = true; error = null; });
    try {
      final result = await MadinatiApi.orders(widget.state.token!);
      if (mounted) setState(() { orders = result; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted && !silent) setState(() => loading = false);
    }
  }
  Future<void> _cancel(dynamic id) async {
    try {
      await MadinatiApi.cancelOrder(widget.state.token!, id);
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إلغاء الطلب.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

class AccountPage extends StatelessWidget {
  final MadinatiState state;
  final VoidCallback onLogin;
  const AccountPage({super.key, required this.state, required this.onLogin});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    const SectionTitle('حسابي'),
    if (!state.loggedIn)
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
        const Icon(Icons.person_outline, size: 54, color: Color(0xFF8F2F08)),
        const Text('سجّل الدخول لإدارة حسابك وطلباتك.'),
        const SizedBox(height: 12),
        FilledButton(onPressed: onLogin, child: const Text('تسجيل الدخول / إنشاء حساب')),
      ])))
    else
      Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        const CircleAvatar(radius: 34, child: Icon(Icons.person, size: 38)),
        const SizedBox(height: 10),
        Text('${state.user?['name']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
        Text('${state.user?['login']}', textDirection: TextDirection.ltr),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: () async {
          await state.logout();
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تسجيل الخروج.')));
        }, icon: const Icon(Icons.logout), label: const Text('تسجيل الخروج')),
      ]))),
    RestaurantInfo(settings: state.settings),
  ]);
}

class RestaurantInfo extends StatelessWidget {
  final Map<String, dynamic> settings;
  const RestaurantInfo({super.key, required this.settings});
  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('معلومات المطعم', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
      const SizedBox(height: 8),
      Text((settings['name'] ?? 'مطاعم مدينتي').toString()),
      if ((settings['phone'] ?? '').toString().isNotEmpty) Text('للتواصل: ${settings['phone']}'),
      const SizedBox(height: 8),
      const Row(children: [Icon(Icons.location_on_outlined, size: 18), SizedBox(width: 5), Text('موقع المطعم على الخريطة')]),
    ])),
  );
}

(String, Color) _status(String s) {
  switch (s) {
    case 'new': return ('جديد', const Color(0xFFFFE7B2));
    case 'accepted': return ('تم القبول', const Color(0xFFD9EAFE));
    case 'ready': return ('جاهز', const Color(0xFFD9F2DD));
    case 'out': return ('خرج للتوصيل', const Color(0xFFE8DDFB));
    case 'delivered': return ('تم التسليم', const Color(0xFFD9F2DD));
    case 'rejected': return ('مرفوض', const Color(0xFFFFD9D9));
    case 'cancelled': return ('ملغي', const Color(0xFFE9E3DF));
    default: return (s, const Color(0xFFE9E3DF));
  }
}
String _money(int n) => n.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',',
);