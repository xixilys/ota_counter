import 'package:flutter/material.dart';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'package:image_picker/image_picker.dart';
import '../services/image_service.dart';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../pages/image_list_page.dart';

class ImagePage extends StatefulWidget {
  const ImagePage({super.key});

  @override
  State<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<ImagePage> {
  String? _currentImagePath;
  List<String> _imageSequence = [];
  int _currentIndex = -1;
  StreamSubscription? _accelerometerSubscription;
  DateTime? _lastShakeTime;
  static const _shakeThreshold = 15.0;
  static const _shakeCooldown = Duration(milliseconds: 1000);
  bool _hasInitialized = false;
  bool _isLocked = false;
  bool _showText = true;
  bool _isPlaceholder = true; // 添加占位符状态

  @override
  void initState() {
    super.initState();
    _initImageSequence(); // 仍然初始化序列，但不显示图片
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasInitialized) {
      _hasInitialized = true;
      _initShakeDetection();
    }
  }

  void _initShakeDetection() {
    _accelerometerSubscription = accelerometerEventStream().listen((event) {
      if (_isLocked) return;

      final acceleration = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );

      final now = DateTime.now();
      if (_lastShakeTime == null ||
          now.difference(_lastShakeTime!) > _shakeCooldown) {
        if (acceleration > _shakeThreshold) {
          _lastShakeTime = now;
          _generateRandomImage();
        }
      }
    });
  }

  Future<void> _initImageSequence() async {
    try {
      final allImages = await ImageService.getUnusedImages(); // 只获取未使用的图片
      if (allImages.isEmpty) {
        setState(() {
          _currentImagePath = null;
          _imageSequence = [];
          _currentIndex = -1;
          _isPlaceholder = true;
        });
        return;
      }

      final shuffled = List<String>.from(allImages)..shuffle();
      setState(() {
        _imageSequence = shuffled;
        _currentIndex = -1;
        _currentImagePath = null;
        _isPlaceholder = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载图片失败: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _generateRandomImage() async {
    if (_isLocked) return;
    if (_imageSequence.isEmpty) {
      await _initImageSequence();
      return;
    }

    setState(() {
      if (_isPlaceholder) {
        _currentIndex = 0;
        _isPlaceholder = false;
      } else {
        _currentIndex = (_currentIndex + 1) % _imageSequence.length;
      }
      _currentImagePath = _imageSequence[_currentIndex];
      _showText = false;
    });

    // 移除自动标记
    // if (_currentImagePath != null) {
    //   await ImageService.markAsUsed(_currentImagePath!);
    //   await _initImageSequence();
    // }
  }

  Future<void> _markCurrentImage() async {
    if (_currentImagePath == null) return;

    try {
      final isUsed = await ImageService.isImageUsed(_currentImagePath!);
      await ImageService.markAsUsed(_currentImagePath!, used: !isUsed);

      // 如果标记为已使用，重新初始化序列
      if (!isUsed) {
        await _initImageSequence();
      }

      setState(() {}); // 刷新界面

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isUsed ? '已取消标记' : '已标记为使用过')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: ${e.toString()}')),
        );
      }
    }
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
    });
  }

  Future<void> _pickImage() async {
    try {
      // 检查权限
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        final sdkInt = androidInfo.version.sdkInt;

        if (sdkInt >= 33) {
          if (!await Permission.photos.isGranted) {
            final status = await Permission.photos.request();
            if (!status.isGranted) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('需要相册权限才能添加图片')),
                );
              }
              return;
            }
          }
        } else {
          if (!await Permission.storage.isGranted) {
            final status = await Permission.storage.request();
            if (!status.isGranted) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('需要存储权限才能添加图片')),
                );
              }
              return;
            }
          }
        }
      }

      final ImagePicker picker = ImagePicker();
      final List<XFile> pickedFiles = await picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (pickedFiles.isEmpty) return;

      // 显示进度对话框
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('正在添加图片...'),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      // 保存所有图片
      for (final pickedFile in pickedFiles) {
        final imageFile = File(pickedFile.path);
        await ImageService.saveImage(imageFile);
      }

      // 关闭进度对话框
      if (mounted) {
        Navigator.of(context).pop();
      }

      // 重新初始化序列
      await _initImageSequence();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已添加 ${pickedFiles.length} 张图片'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // 确保进度对话框被关闭
      if (mounted) {
        Navigator.of(context).maybePop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: ${e.toString()}')),
        );
      }
    }
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appBarColor =
        Theme.of(context).colorScheme.inversePrimary.withAlpha(204);
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: const Text('抽取图片'),
        backgroundColor: appBarColor,
        actions: [
          if (_currentImagePath != null) // 只在显示图片时显示标记按钮
            FutureBuilder<bool>(
              future: ImageService.isImageUsed(_currentImagePath!),
              builder: (context, snapshot) {
                final isUsed = snapshot.data ?? false;
                return IconButton(
                  icon: Icon(
                    isUsed ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: isUsed ? Colors.green : Colors.white,
                  ),
                  onPressed: _markCurrentImage,
                  tooltip: isUsed ? '取消标记' : '标记为已使用',
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.photo_library),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ImageListPage(),
              ),
            ).then((_) => _initImageSequence()), // 返回时重新加载序列
            tooltip: '图片列表',
          ),
          IconButton(
            icon: const Icon(Icons.add_photo_alternate),
            onPressed: _pickImage,
            tooltip: '添加图片',
          ),
          IconButton(
            icon: Icon(_isLocked ? Icons.lock : Icons.lock_open),
            onPressed: _toggleLock,
            tooltip: _isLocked ? '解锁' : '锁定',
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _generateRandomImage,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isPlaceholder || _currentImagePath == null)
              Container(
                color: Colors.grey[200],
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.photo_library_outlined,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _imageSequence.isEmpty ? '暂无图片\n请先上传' : '点击或摇晃\n开始抽取',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Image.file(
                File(_currentImagePath!),
                fit: BoxFit.contain,
                width: screenSize.width,
                height: screenSize.height,
              ),
            if (_currentImagePath != null && _showText)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.4),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.4),
                    ],
                    stops: const [0.0, 0.3, 0.7, 1.0],
                  ),
                ),
                child: const Center(
                  child: Text(
                    '点击或摇晃手机\n随机抽取',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 3,
                          offset: Offset(1, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_isLocked)
              Positioned(
                top: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.lock,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
