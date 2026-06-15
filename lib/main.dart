import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const MyApp());
}

const Color kPrimary = Color(0xFF6B4226); // ← change to your brand color

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'بيانات الدخول المطلوبة',
      debugShowCheckedModeBanner: false,
      home: const WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _webViewController;
  StreamSubscription<Uri>? _deepLinkSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  bool _isOffline = false;
  double _progress = 0.0;
  bool _showProgress = false; // only show bar after first interaction

  String _currentUrl = '';
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
    _initConnectivityListener();
    _checkInitialConnectivity();
  }

  Future<void> _checkInitialConnectivity() async {
    final result = await Connectivity().checkConnectivity();

    if (mounted) {
      setState(() {
        _isOffline = result == ConnectivityResult.none;
      });
    }
  }

  void _initConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOffline = _isOffline;
      final nowOffline =
          results.contains(ConnectivityResult.none) || results.isEmpty;

      if (mounted) {
        setState(() => _isOffline = nowOffline);
      }

      if (nowOffline) {
        // Stop loading and clear WebView content when offline
        _webViewController?.stopLoading();
        _webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri('about:blank')),
        );
      }

      // Only reload if coming back online and not on about:blank
      if (wasOffline && !nowOffline) {
        if (_currentUrl.isEmpty || _currentUrl == 'about:blank') {
          _webViewController?.loadUrl(
            urlRequest: URLRequest(
              url: WebUri('https://www.mawasm.kayan1.com:2083'),
            ),
          );
        } else {
          _webViewController?.reload();
        }
      }
    });
  }

  DateTime? _lastBackPressed;

  Future<void> _initDeepLinks() async {
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) _handleDeepLink(initialUri);
    _deepLinkSub = _appLinks.uriLinkStream.listen(_handleDeepLink);
  }

  void _handleDeepLink(Uri uri) {
    final token =
        uri.queryParameters['token'] ??
        (uri.fragment.isNotEmpty ? uri.fragment : null);
    if (token != null && token.isNotEmpty && _webViewController != null) {
      final payload = jsonEncode({'token': token});
      _webViewController?.evaluateJavascript(
        source:
            "window.dispatchEvent(new CustomEvent('flutterDeepLink', {detail: $payload}));",
      );
      _webViewController?.evaluateJavascript(
        source:
            """
          (function(){
            try {
              localStorage.setItem('auth_token', '$token');
              sessionStorage.setItem('auth_token', '$token');
              window.location.reload();
            } catch(e) {}
          })();
        """,
      );
    }
  }

  bool get needsTopPadding {
    if (_currentUrl.isEmpty) return false;
    final normalized = _currentUrl
        .replaceAll(RegExp(r'/$'), '')
        .split('?')[0]
        .split('#')[0]
        .trim();
    const protectedPaths = ['/home', '/cart', '/wishlist', '/categories'];
    return protectedPaths.any((path) => normalized.endsWith(path));
  }

  void _retryLoad() {
    Connectivity().checkConnectivity().then((result) {
      final isNowOnline = result != ConnectivityResult.none;
      if (isNowOnline) {
        if (mounted) setState(() => _isOffline = false);
        // Only load the main page if currently blank or offline
        if (_currentUrl.isEmpty || _currentUrl == 'about:blank' || _isOffline) {
          _webViewController?.loadUrl(
            urlRequest: URLRequest(
              url: WebUri('https://mawasm.kayan1.com:2083'),
            ),
          );
        } else {
          _webViewController?.reload();
        }
      } else {
        if (mounted) {
          setState(() => _isOffline = true);
          _webViewController?.loadUrl(
            urlRequest: URLRequest(url: WebUri('about:blank')),
          );
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Still no internet connection.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }

  Future<bool> _showExitDialog() async {
    return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Exit App'),
            content: const Text('Do you really want to exit?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Yes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _onWillPop() async {
    // 1. If WebView can go back → go back
    if (_webViewController != null && await _webViewController!.canGoBack()) {
      _webViewController!.goBack();
      return false;
    }

    // 2. Double press logic
    final now = DateTime.now();

    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );

      return false;
    }

    // 3. Show confirmation dialog
    return await _showExitDialog();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            // ── WebView only created when online ──
            if (!_isOffline)
              Padding(
                padding: EdgeInsets.only(top: kToolbarHeight),
                child: Padding(
                  padding: const EdgeInsets.only(top: 0),
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(
                      url: WebUri('https://mawasm.kayan1.com:2083'),
                    ),
                    initialOptions: InAppWebViewGroupOptions(
                      crossPlatform: InAppWebViewOptions(
                        javaScriptEnabled: true,
                        cacheEnabled: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        useShouldOverrideUrlLoading: true,
                        userAgent: 'random',
                      ),
                      android: AndroidInAppWebViewOptions(
                        useHybridComposition: true,
                        mixedContentMode:
                            AndroidMixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                        safeBrowsingEnabled: false,
                      ),
                      ios: IOSInAppWebViewOptions(
                        allowsInlineMediaPlayback: true,
                        allowsBackForwardNavigationGestures: true,
                      ),
                    ),
                    onWebViewCreated: (controller) {
                      _webViewController = controller;

                      controller.addJavaScriptHandler(
                        handlerName: 'openExternal',
                        callback: (args) async {
                          if (args.isEmpty || args[0] == null)
                            return {'status': 'error'};
                          try {
                            await launchUrl(
                              Uri.parse(args[0].toString()),
                              mode: LaunchMode.externalApplication,
                            );
                            return {'status': 'ok'};
                          } catch (e) {
                            return {'status': 'error', 'message': e.toString()};
                          }
                        },
                      );

                      controller.addJavaScriptHandler(
                        handlerName: 'showNotification',
                        callback: (args) {
                          if (args.isEmpty || args[0] == null) return;
                          final data = args[0] as Map<dynamic, dynamic>?;
                          if (data == null) return;
                          final title =
                              data['title']?.toString() ?? 'New Notification';
                          final body = data['body']?.toString() ?? '';
                          final url = data['url']?.toString();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: kPrimary,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  if (body.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      body,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              duration: const Duration(seconds: 6),
                              action: url != null
                                  ? SnackBarAction(
                                      label: 'View',
                                      textColor: Colors.white,
                                      onPressed: () =>
                                          _webViewController?.loadUrl(
                                            urlRequest: URLRequest(
                                              url: WebUri(url),
                                            ),
                                          ),
                                    )
                                  : null,
                            ),
                          );
                        },
                      );
                    },
                    shouldOverrideUrlLoading: (controller, action) async =>
                        NavigationActionPolicy.ALLOW,
                    onProgressChanged: (controller, progress) {
                      if (mounted) {
                        setState(() {
                          _progress = progress / 100;
                          _showProgress = _progress < 1.0;
                        });
                      }
                    },
                    onLoadStart: (controller, url) {
                      if (mounted) setState(() => _showProgress = true);
                    },
                    onLoadStop: (controller, url) async {
                      if (url != null && mounted) {
                        setState(() => _currentUrl = url.toString());
                      }
                      if (mounted) {
                        setState(() {
                          _progress = 1.0;
                          _showProgress = false;
                        });
                      }
                    },
                    onUpdateVisitedHistory: (controller, url, _) {
                      if (url != null && mounted) {
                        setState(() => _currentUrl = url.toString());
                      }
                    },
                    onLoadError: (controller, url, code, message) {
                      // If network error, set offline mode and show offline screen
                      if (code == -2 ||
                          code == -6 ||
                          code == -7 ||
                          code == -8 ||
                          code == -14) {
                        // Common network error codes for WebView
                        if (mounted) setState(() => _isOffline = true);
                        return;
                      }
                      if (mounted) setState(() => _showProgress = false);
                    },
                  ),
                ),
              ),

            // ── Thin top progress bar (only while loading) ──
            if (_showProgress && !_isOffline)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showProgress ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: LinearProgressIndicator(
                    value: _progress < 1.0 ? _progress : null,
                    backgroundColor: Colors.transparent,
                    valueColor: const AlwaysStoppedAnimation<Color>(kPrimary),
                    minHeight: 3,
                  ),
                ),
              ),

            // ── Offline screen ──
            if (_isOffline) _buildOfflineScreen(),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineScreen() {
    return Container(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kPrimary.withOpacity(0.08),
                ),
                child: Icon(
                  Icons.wifi_off_rounded,
                  size: 38,
                  color: kPrimary.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'No Internet Connection',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF222222),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Please check your connection\nand try again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500],
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),
              GestureDetector(
                onTap: _retryLoad,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: kPrimary,
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: kPrimary.withOpacity(0.3),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.refresh_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Try Again',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
