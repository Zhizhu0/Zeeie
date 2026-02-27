import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:io';
import 'dart:collection';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'user_script_manager.dart';
import 'user_script_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
  );
  
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();

    await windowManager.setPreventClose(true);
  });

  await UserScriptManager.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin, WindowListener {
  late AnimationController _controller;

  // 本地服务器相关
  late InAppLocalhostServer localhostServer;
  int _actualPort = 8080;

  // 极光动画相关
  late Animation<Offset> _blob1Anim;
  late Animation<Offset> _blob2Anim;
  late Animation<Offset> _blob3Anim;

  List<Star> _stars = [];

  // 侧边栏控件
  final List<SidebarItem> _sidebarItems = [];

  // --- 页面控制逻辑 ---
  int _currentIndex = 0;

  // --- InAppWebView 控制器 ---
  InAppWebViewController? _webViewController;

  late List<AppItem> myApps;

  UserScript? _biliUserScript;
  List<UserScriptConfig> _allScripts = [];
  List<UserScriptConfig> _enabledScripts = [];

  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? webViewController;
  bool _isFullscreen = false;

  Rect? _previousBounds;
  bool _wasMaximizedBeforeFullscreen = false; 

  @override
  void initState() {
    super.initState();

    windowManager.addListener(this);

    _startServer();
    
    // 初始化动画
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat(reverse: true);

    _blob1Anim = Tween<Offset>(
      begin: const Offset(-100, 0),
      end: const Offset(100, 50),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine));

    _blob2Anim = Tween<Offset>(
      begin: const Offset(50, 0),
      end: const Offset(-50, 100),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutQuad));

    _blob3Anim = Tween<Offset>(
      begin: const Offset(0, -50),
      end: const Offset(50, 50),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    final random = math.Random();
    _stars = List.generate(1000, (index) {
      return Star(
        x: random.nextDouble() * 3000,
        y: random.nextDouble() * 2000,
        size: random.nextDouble() * 2 + 0.5,
        opacitySpeed: random.nextDouble() * 0.5 + 0.5,
      );
    });

    // 初始化 App 列表
    myApps = [
      _buildAppItem("bilibili", "assets/icons/bilibili.svg", "https://www.bilibili.com/"),
      _buildAppItem("Pixiv", "assets/icons/pixiv.svg", "https://www.pixiv.net/"),
      _buildAppItem("设置", Icons.settings, "assets/web/settings.html"),
    ];

    _loadUserScripts();
  }

  Future<void> _startServer() async {
    var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _actualPort = socket.port;
    await socket.close();

    localhostServer = InAppLocalhostServer(port: _actualPort);
    await localhostServer.start();
    setState(() {});
  }

  Future<void> _loadUserScripts() async {
    try {
      final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  
      final List<String> scripts = manifest.listAssets()
        .where((String key) => key.startsWith('assets/scripts/') && !key.startsWith('assets/scripts/shims/'))
        .toList();
      _allScripts.clear();

      for (var scriptPath in scripts) {
        String jsContent = await rootBundle.loadString(scriptPath);
        
        var config = UserScriptManager.parse(
          jsContent,
          scriptPath: scriptPath,
          sourceType: 'system',
        );
        _allScripts.add(config);
      }
      _rebuildEnabledScripts();
    } catch (e) {
      debugPrint("Failed to load user script: $e");
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    // localhostServer.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    try {
      // 1. 异步安全地关闭本地服务器 (必须 await)
      await localhostServer.close();

      // 2. 如果你在全屏状态下关闭了应用，建议先把状态还原，防止句柄泄露
      if (_isFullscreen) {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }

      // 3. 解除对窗口关闭的阻止
      await windowManager.setPreventClose(false);

      // 4. 彻底销毁并退出应用
      await windowManager.destroy();
    } catch (e) {
      debugPrint("关闭时发生错误: $e");
      // 无论如何，最后一定要保底退出
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Stack(
        children: [
          // --- 层1: 动态光晕背景 ---
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Stack(
                  children: [
                    Positioned(
                      bottom: -100 + _blob1Anim.value.dy,
                      left: -100 + _blob1Anim.value.dx,
                      child: _buildBlurBlob(
                        color: const Color.fromRGBO(255, 152, 0, 0.6),
                        size: size.width * 0.8,
                      ),
                    ),
                    Positioned(
                      bottom: -50 + _blob2Anim.value.dy,
                      right: -100 + _blob2Anim.value.dx,
                      child: _buildBlurBlob(
                        color: const Color.fromRGBO(233, 30, 99, 0.5),
                        size: size.width * 0.9,
                      ),
                    ),
                    Positioned(
                      top: -100 + _blob3Anim.value.dy,
                      right: 0,
                      left: 0,
                      child: _buildBlurBlob(
                        color: const Color.fromRGBO(63, 81, 181, 0.5),
                        size: size.width * 1.0,
                      ),
                    ),
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 80.0, sigmaY: 80.0),
                      child: Container(color: Colors.transparent),
                    ),
                  ],
                );
              },
            ),
          ),

          // --- 层2: 星空粒子 ---
          Positioned.fill(
            child: CustomPaint(
              painter: StarFieldPainter(_controller, _stars),
            ),
          ),

          // --- 层3: 页面布局 (Sidebar + IndexedStack) ---
          Row(
            children: [
              // 侧边栏
              if (!_isFullscreen)
                SizedBox(
                  width: 100,
                  child: _buildGlassSidebar(),
                ),
              // 右侧内容区域
              Expanded(
                flex: 1,
                child: IndexedStack(
                  index: _currentIndex,
                  children: [
                    // Index 0: 主页 GridView
                    Container(
                      padding: const EdgeInsets.all(40),
                      child: GridView.builder(
                        padding: const EdgeInsets.all(24),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 100,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 20,
                          childAspectRatio: 0.8,
                        ),
                        itemCount: myApps.length,
                        itemBuilder: (context, index) {
                          return _buildGridItem(myApps[index]);
                        },
                      ),
                    ),
                    
                    for (var item in _sidebarItems) ... [
                      _buildWebPage(item.url, ValueKey(item.url))
                    ]
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBlurBlob({required Color color, required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }

  // 构建玻璃拟态侧边栏
  Widget _buildGlassSidebar() {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
        child: Container(
          decoration: const BoxDecoration(
            color: Color.fromRGBO(255, 255, 255, 0.05),
            border: Border(
              right: BorderSide(
                color: Color.fromRGBO(255, 255, 255, 0.1), 
                width: 1
              ),
            ),
          ),
          child: SlidableAutoCloseBehavior(
            child: Column(
              children: [
                const SizedBox(height: 30),
                _buildMenuItem(SidebarItem(label: "主页", url: "", icon: Icons.home_filled), 0),

                for (int i = 0; i < _sidebarItems.length; i++) ...[
                  const SizedBox(height: 20),
                  _buildMenuItem(_sidebarItems[i], i + 1),
                ],
              ],
            ),
          )
        ),
      ),
    );
  }

  Widget _buildWebPage(String url, Key key) {
    return ClipRRect(
      key: key,
      // 沉浸式铺满：全屏时取消圆角
      borderRadius: _isFullscreen 
          ? BorderRadius.zero 
          : const BorderRadius.only(
              topLeft: Radius.circular(20), 
              bottomLeft: Radius.circular(20)
            ),
      child: InAppWebView(
        initialUserScripts: UnmodifiableListView<UserScript>(
          _enabledScripts.map((config) => UserScript(
            source: UserScriptManager.generateInjectionCode(config),
            injectionTime: config.runAt == "document-start" ? UserScriptInjectionTime.AT_DOCUMENT_START : UserScriptInjectionTime.AT_DOCUMENT_END,
          )).toList(),
        ),
        initialUrlRequest: URLRequest(
          url: url.startsWith('http') 
            ? WebUri(url) 
            : WebUri("http://localhost:$_actualPort/$url")
        ),
        initialSettings: InAppWebViewSettings(
          isInspectable: true,
          transparentBackground: true,
          javaScriptEnabled: true,
          allowFileAccessFromFileURLs: true, 
          allowUniversalAccessFromFileURLs: true,
          isElementFullscreenEnabled: true, 
          allowsInlineMediaPlayback: true,
          allowsPictureInPictureMediaPlayback: true,
          builtInZoomControls: true,
          displayZoomControls: false, 
          iframeAllowFullscreen: true,
          mediaPlaybackRequiresUserGesture: false,
        ),
        onWebViewCreated: (controller) {
          webViewController = controller;
          _registerWebViewHandlers(controller);
        },
      ),
    );
  }

  void _registerWebViewHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'zeeieGetUserScriptList',
      callback: (args) async {
        final scriptId = args.isNotEmpty ? args[0]?.toString() ?? '' : '';
        if (scriptId.isEmpty) return <dynamic>[];
        if (!UserScriptManager.scriptHasGrant(scriptId, 'Zeeie_getUserScriptList')) return <dynamic>[];

        final result = _allScripts.map((config) {
          final lock = _isLockEffective(config);
          final enabled = _isScriptEnabled(config);
          return {
            'scriptId': config.scriptId,
            'namespace': config.namespace,
            'name': config.name,
            'author': config.author,
            'version': config.version,
            'enabled': enabled,
            'lock': lock,
            'type': config.sourceType,
          };
        }).toList();
        return result;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieSetUserScriptEnable',
      callback: (args) async {
        if (args.length < 3) return false;
        final callerScriptId = args[0]?.toString() ?? '';
        final targetScriptId = args[1]?.toString() ?? '';
        final enabled = args[2] == true;
        if (callerScriptId.isEmpty || targetScriptId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(callerScriptId, 'Zeeie_setUserScriptEnable')) return false;

        UserScriptConfig? config;
        for (final s in _allScripts) {
          if (s.scriptId == targetScriptId) {
            config = s;
            break;
          }
        }
        if (config == null) return false;
        if (_isLockEffective(config)) return false;

        await UserScriptStorage.instance.setScriptEnabled(targetScriptId, enabled);
        setState(() {
          _rebuildEnabledScripts();
        });
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'gmStorageSet',
      callback: (args) async {
        if (args.length < 3) return false;
        final scriptId = args[0]?.toString() ?? '';
        final key = args[1]?.toString() ?? '';
        final encodedValue = args[2];
        if (scriptId.isEmpty || key.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(scriptId, 'GM_setValue')) return false;
        await UserScriptStorage.instance.setValue(scriptId, key, encodedValue);
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'gmStorageDelete',
      callback: (args) async {
        if (args.length < 2) return false;
        final scriptId = args[0]?.toString() ?? '';
        final key = args[1]?.toString() ?? '';
        if (scriptId.isEmpty || key.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(scriptId, 'GM_deleteValue')) return false;
        await UserScriptStorage.instance.deleteValue(scriptId, key);
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieToggleFullscreen',
      callback: (args) async {
        if (args.length < 2) return false;
        final scriptId = args[0]?.toString() ?? '';
        if (scriptId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(scriptId, 'Zeeie_toggleFullscreen')) return false;
        final shouldFullscreen = args[1] == true;
        await _handleToggleFullscreen(shouldFullscreen);
        return true;
      },
    );
  }

  bool _isLockEffective(UserScriptConfig config) {
    return config.sourceType == 'system' && config.lock == true;
  }

  bool _isScriptEnabled(UserScriptConfig config) {
    if (_isLockEffective(config)) return true;
    return UserScriptStorage.instance.getScriptEnabled(config.scriptId, defaultValue: true);
  }

  void _rebuildEnabledScripts() {
    _enabledScripts = _allScripts.where((config) => _isScriptEnabled(config)).toList();
  }

  Future<void> _handleToggleFullscreen(bool shouldFullscreen) async {
    if (shouldFullscreen != _isFullscreen) {
      if (shouldFullscreen) {
        _wasMaximizedBeforeFullscreen = await windowManager.isMaximized();

        if (_wasMaximizedBeforeFullscreen) {
          await windowManager.unmaximize();
          await Future.delayed(const Duration(milliseconds: 100));
        }

        _previousBounds = await windowManager.getBounds();

        List<Display> displays = await screenRetriever.getAllDisplays();
        Display targetDisplay = displays.first;
        for (var display in displays) {
          if (_previousBounds!.center.dx >= display.visiblePosition!.dx &&
              _previousBounds!.center.dx <= display.visiblePosition!.dx + display.size.width) {
            targetDisplay = display;
            break;
          }
        }

        await windowManager.setAsFrameless();
        await windowManager.setAlwaysOnTop(true);

        await windowManager.setBounds(Rect.fromLTWH(
          targetDisplay.visiblePosition!.dx,
          targetDisplay.visiblePosition!.dy,
          targetDisplay.size.width,
          targetDisplay.size.height,
        ));

        setState(() { _isFullscreen = true; });
      } else {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);

        if (_previousBounds != null) {
          await windowManager.setBounds(_previousBounds!);
        }
        if (_wasMaximizedBeforeFullscreen) {
          await windowManager.maximize();
        } else {
          if (_previousBounds != null) {
            await windowManager.setBounds(_previousBounds!);
          }
        }

        setState(() { _isFullscreen = false; });
      }
    }
  }

  // 侧边栏菜单项封装
  Widget _buildMenuItem(SidebarItem item, int index) {
    return Slidable(
      // key 是必须的，用于标识列表中的项
      key: ValueKey(item.hashCode), 
      enabled: index != 0, 

      // 右侧滑出的面板（从右往左划）
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.5, // 侧滑区域占比
        children: [
          CustomSlidableAction(
            onPressed: (context) {
              // 这里执行关闭逻辑
              _handleClose(index - 1);
            },
            backgroundColor: Colors.transparent,
            child: const Icon(
              Icons.close,
              size: 20,
              color: Colors.white70,
            ),
          ),
        ],
      ),

      // 原有的内容部分
      child: Builder(
        builder: (context) {
          return InkWell(
            onTap: () {
              setState(() {
                _currentIndex = index;
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 12),
              width: double.infinity,
              decoration: _currentIndex == index
                  ? const BoxDecoration(
                      border: Border(left: BorderSide(color: Colors.orangeAccent, width: 3)),
                      gradient: LinearGradient(
                        colors: [Color.fromRGBO(255, 255, 255, 0.1), Colors.transparent],
                      ),
                    )
                  : null,
              child: Center(
                child: _buildSidebarIcon(item.icon, _currentIndex == index),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGridItem(AppItem appItem) {
    return InkWell(
      onTap: appItem.onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: const Color.fromRGBO(255, 255, 255, 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: _buildIcon(appItem.icon),
          ),
          const SizedBox(height: 10),
          Text(
            appItem.name,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(dynamic iconSource) {
    const double iconSize = 40.0;
    
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Center(
        child: () {
          if (iconSource is IconData) {
            return Icon(iconSource, size: iconSize, color: Colors.white);
          } 
          if (iconSource is String) {
            if (iconSource.endsWith('.svg')) {
              return SvgPicture.asset(
                iconSource,
                width: iconSize,
                height: iconSize,
                placeholderBuilder: (context) => const CircularProgressIndicator(),
              );
            } else {
              return Image.asset(
                iconSource, 
                width: iconSize,
                height: iconSize,
                fit: BoxFit.contain,
              );
            }
          }
          return const Icon(Icons.help_outline, color: Colors.white);
        }(),
      ),
    );
  }

  Widget _buildSidebarIcon(dynamic iconSource, bool isActive) {
    const double iconSize = 26.0;
    
    // 1. 处理系统图标 IconData
    if (iconSource is IconData) {
      return Icon(
        iconSource,
        size: iconSize,
        color: isActive ? Colors.white : Colors.white54,
      );
    } 
    
    // 2. 处理字符串路径 (PNG 或 SVG)
    if (iconSource is String) {
      Widget imageWidget;
      
      if (iconSource.endsWith('.svg')) {
        // 如果是 SVG 路径
        imageWidget = SvgPicture.asset(
          iconSource,
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          // SVG 报错处理（可选）
          placeholderBuilder: (context) => const Icon(Icons.broken_image, size: iconSize, color: Colors.white24),
        );
      } else {
        // 如果是普通的 PNG/JPG 路径
        imageWidget = Image.asset(
          iconSource,
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => 
              const Icon(Icons.broken_image, size: iconSize, color: Colors.white24),
        );
      }

      // 统一应用透明度（未激活状态变淡）
      return Opacity(
        opacity: isActive ? 1.0 : 0.5, 
        child: imageWidget,
      );
    }

    return const SizedBox(width: iconSize, height: iconSize);
  }

  AppItem _buildAppItem(String name, dynamic icon, String url) {
    return AppItem(
        name: name, 
        icon: icon, // 你的图片路径
        onTap: () {
          bool isFinded = false;
          for (var item in _sidebarItems) {
            if (item.label == name) {
              isFinded = true;
              setState(() {
                _currentIndex = _sidebarItems.indexOf(item) + 1; // 切换显示层级
              });
              break;
            }
          }
          if (!isFinded) {
            setState(() {
              _sidebarItems.add(
                SidebarItem(
                  label: name, 
                  url: url, 
                  icon: icon,
                )
              );
              _currentIndex = _sidebarItems.length; // 切换显示层级
            });
          }
        }
      );
  }
  void _handleClose(int indexInSidebar) {
    setState(() {
      int targetStackIndex = indexInSidebar + 1; // 在 Stack 中的实际索引

      if (_currentIndex == targetStackIndex) {
        // 1. 如果关闭的是当前正在看的页面 -> 回到主页
        _currentIndex = 0;
      } else if (_currentIndex > targetStackIndex) {
        // 2. 如果关闭的是当前页面“左侧/上方”的页面 -> 索引减 1 保持指向原页面
        _currentIndex--;
      }

      // 3. 移除数据
      _sidebarItems.removeAt(indexInSidebar);
    });
  }
  
}

class StarFieldPainter extends CustomPainter {
  final Animation<double> animation;
  final List<Star> stars;

  StarFieldPainter(this.animation, this.stars) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;

    for (var star in stars) {
      double opacity = (math.sin(animation.value * 2 * math.pi * star.opacitySpeed) + 1) / 2; 
      opacity = 0.1 + (opacity * 0.5);
      paint.color = Color.fromRGBO(255, 255, 255, opacity);
      canvas.drawCircle(Offset(star.x, star.y), star.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class Star {
  double x, y, size, opacitySpeed;
  Star({required this.x, required this.y, required this.size, required this.opacitySpeed});
}

class AppItem {
  final String name;
  final dynamic icon;
  final VoidCallback onTap;

  AppItem({required this.name, required this.icon, required this.onTap});
}

class SidebarItem {
  final String label;
  final String url;
  final dynamic icon;

  SidebarItem({required this.label, required this.url, required this.icon});
}
