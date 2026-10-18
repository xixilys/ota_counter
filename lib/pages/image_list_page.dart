import 'package:flutter/material.dart';
import 'dart:io';
import '../services/image_service.dart';

class ImageListPage extends StatefulWidget {
  const ImageListPage({super.key});

  @override
  State<ImageListPage> createState() => _ImageListPageState();
}

class _ImageListPageState extends State<ImageListPage> {
  List<String> _imagePaths = [];
  Map<String, bool> _imageUsage = const {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    setState(() => _isLoading = true);
    try {
      final paths = await ImageService.getAllImages();
      final usage = await ImageService.getImageUsageByPath();
      setState(() {
        _imagePaths = paths;
        _imageUsage = usage;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: ${e.toString()}')),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteImage(String path) async {
    try {
      await ImageService.deleteImage(path);
      await _loadImages();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _toggleUsedStatus(String path) async {
    try {
      final isUsed = _imageUsage[path] ?? false;
      await ImageService.markAsUsed(path, used: !isUsed);
      if (!mounted) {
        return;
      }
      setState(() {
        _imageUsage = {..._imageUsage, path: !isUsed};
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isUsed ? '已取消标记' : '已标记为使用过')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: ${e.toString()}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('图片列表'),
        backgroundColor:
            Theme.of(context).colorScheme.inversePrimary.withAlpha(204),
      ),
      body: _imagePaths.isEmpty
          ? const Center(child: Text('暂无图片'))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: _imagePaths.length,
              itemBuilder: (context, index) {
                final path = _imagePaths[index];
                final isUsed = _imageUsage[path] ?? false;
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        cacheWidth: 600,
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(isUsed
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked),
                              onPressed: () => _toggleUsedStatus(path),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor:
                                    isUsed ? Colors.green : Colors.white,
                              ),
                              tooltip: isUsed ? '取消标记' : '标记为已使用',
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () => _showDeleteDialog(path),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                            ),
                            if (isUsed)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check_circle,
                                      color: Colors.green,
                                      size: 16,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '已使用',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _showDeleteDialog(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这张图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _deleteImage(path);
    }
  }
}
