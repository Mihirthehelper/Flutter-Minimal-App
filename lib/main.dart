import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  runApp(MyApp(db: db));
}

class MyApp extends StatelessWidget {
  final Database db;
  MyApp({required this.db});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grocery Scanner Demo',
      home: HomePage(db: db),
    );
  }
}

class HomePage extends StatefulWidget {
  final Database db;
  HomePage({required this.db});
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> frequent = [];

  @override
  void initState() {
    super.initState();
    _loadFrequent();
  }

  Future<void> _loadFrequent() async {
    final rows = await widget.db.query(
      'items',
      orderBy: 'scan_count DESC',
      limit: 10,
    );
    setState(() => frequent = rows);
  }

  void _openScanner() async {
    final barcode = await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ScannerPage()));
    if (barcode != null) {
      final product = await lookupProduct(barcode);
      if (product != null) {
        await saveOrUpdateItem(widget.db, barcode, product);
        await _loadFrequent();
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ProductPage(
                      barcode: barcode,
                      product: product,
                      db: widget.db,
                    )));
      } else {
        // No product found; allow user to save basic record
        final basic = {'product_name': 'Unknown product', 'brands': ''};
        await saveOrUpdateItem(widget.db, barcode, basic);
        await _loadFrequent();
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ProductPage(
                      barcode: barcode,
                      product: basic,
                      db: widget.db,
                    )));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(title: Text('Grocery Scanner')),
        body: Column(
          children: [
            Expanded(
                child: frequent.isEmpty
                    ? Center(child: Text('No items scanned yet'))
                    : ListView.builder(
                        itemCount: frequent.length,
                        itemBuilder: (ctx, i) {
                          final item = frequent[i];
                          return ListTile(
                            leading: item['image_url'] != null
                                ? Image.network(item['image_url'], width: 48, height: 48, errorBuilder: (_,__,___)=>Icon(Icons.image))
                                : Icon(Icons.shopping_basket),
                            title: Text(item['name'] ?? item['barcode']),
                            subtitle: Text('Scanned ${item['scan_count']} times'),
                          );
                        })),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton.icon(
                  onPressed: _openScanner,
                  icon: Icon(Icons.qr_code_scanner),
                  label: Text('Scan barcode')),
            )
          ],
        ));
  }
}

class ScannerPage extends StatefulWidget {
  @override
  _ScannerPageState createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  MobileScannerController controller = MobileScannerController();
  bool _scanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcode')),
      body: MobileScanner(
        controller: controller,
        onDetect: (barcode, args) async {
          if (_scanned) return;
          final String? code = barcode.rawValue;
          if (code == null) return;
          _scanned = true;
          Navigator.pop(context, code);
        },
      ),
    );
  }
}

class ProductPage extends StatelessWidget {
  final String barcode;
  final Map<String, dynamic> product;
  final Database db;
  ProductPage({required this.barcode, required this.product, required this.db});

  @override
  Widget build(BuildContext context) {
    final name = product['product_name'] ?? product['product'] ?? 'Unknown';
    final brands = product['brands'] ?? '';
    final image = product['image_url'] ??
        (product['product'] != null ? product['product']['image_url'] : null);

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (image != null)
              Image.network(image, height: 160, errorBuilder: (_,__,___)=>Icon(Icons.image, size: 160)),
            SizedBox(height: 12),
            Text(name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (brands.isNotEmpty) Text('Brand: $brands'),
            SizedBox(height: 12),
            ElevatedButton(
                onPressed: () async {
                  await widgetDbIncrementScan(db: db, barcode: barcode);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Marked purchased')));
                },
                child: Text('Mark Purchased'))
          ],
        ),
      ),
    );
  }
}

// ---------------------- DB helpers ----------------------

class AppDatabase {
  static Future<Database> open() async {
    final documents = await getApplicationDocumentsDirectory();
    final dbPath = join(documents.path, 'grocery_scanner.db');
    return openDatabase(dbPath, version: 1, onCreate: (db, v) async {
      await db.execute('''
        CREATE TABLE items(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          barcode TEXT UNIQUE,
          name TEXT,
          brand TEXT,
          image_url TEXT,
          scan_count INTEGER DEFAULT 0,
          last_scanned_at TEXT,
          additional_json TEXT
        )
      ''');
    });
  }
}

Future<void> saveOrUpdateItem(Database db, String barcode, Map<String, dynamic> product) async {
  final name = product['product_name'] ?? product['product'] ?? '';
  final brand = product['brands'] ?? '';
  final image = product['image_url'] ??
      (product['product'] != null ? product['product']['image_url'] : null);
  final existed = await db.query('items', where: 'barcode=?', whereArgs: [barcode]);
  final now = DateTime.now().toIso8601String();
  final addJson = jsonEncode(product);
  if (existed.isEmpty) {
    await db.insert('items', {
      'barcode': barcode,
      'name': name,
      'brand': brand,
      'image_url': image,
      'scan_count': 1,
      'last_scanned_at': now,
      'additional_json': addJson
    });
  } else {
    final currentCount = existed.first['scan_count'] as int? ?? 0;
    await db.update(
        'items',
        {
          'name': name,
          'brand': brand,
          'image_url': image,
          'scan_count': currentCount + 1,
          'last_scanned_at': now,
          'additional_json': addJson
        },
        where: 'barcode=?',
        whereArgs: [barcode]);
  }
}

Future<void> widgetDbIncrementScan({required Database db, required String barcode}) async {
  final rows = await db.query('items', where: 'barcode=?', whereArgs: [barcode]);
  if (rows.isNotEmpty) {
    final cur = rows.first['scan_count'] as int? ?? 0;
    await db.update('items', {'scan_count': cur + 1, 'last_scanned_at': DateTime.now().toIso8601String()},
        where: 'barcode=?', whereArgs: [barcode]);
  }
}

// ---------------------- Open Food Facts lookup ----------------------

Future<Map<String, dynamic>?> lookupProduct(String barcode) async {
  // Open Food Facts JSON API
  final url = Uri.parse('https://world.openfoodfacts.org/api/v0/product/$barcode.json');
  try {
    final resp = await http.get(url);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] == 1) {
        // product found
        final product = data['product'] as Map<String, dynamic>;
        return product;
      }
      return null;
    } else {
      return null;
    }
  } catch (e) {
    return null;
  }
}
