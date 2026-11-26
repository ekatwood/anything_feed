import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'make_post.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const TrendingNowApp());
}

class TrendingNowApp extends StatefulWidget {
  const TrendingNowApp({Key? key}) : super(key: key);

  @override
  State<TrendingNowApp> createState() => _TrendingNowAppState();
}

class _TrendingNowAppState extends State<TrendingNowApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void _toggleTheme(bool isDark) {
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    const baseTextTheme = TextTheme(
      bodyLarge: TextStyle(fontSize: 21),
      bodyMedium: TextStyle(fontSize: 19),
      bodySmall: TextStyle(fontSize: 17),
    );
    const Color _lightRedSeed = Color(0xFFE57373); // soft/light red (Material Red 300)
    const Color _lightRedSurface = Color(0xFFFFF5F5); // subtle blush tint for background
    const Color _lightRedCard = Color(0xFFFFFAFA); // clean soft-rose card surface
    const Color _darkRedSeed = Color(0xFFEF9A9A); // gentle coral-red for dark mode

    final lightColorScheme = ColorScheme.fromSeed(
      seedColor: _lightRedSeed,
      brightness: Brightness.light,
    );

    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: _darkRedSeed,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Trending Now',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightColorScheme,
        brightness: Brightness.light,
        scaffoldBackgroundColor: _lightRedSurface,
        fontFamily: 'CormorantGaramond',
        textTheme: baseTextTheme,
        tooltipTheme: const TooltipThemeData(
          textStyle: TextStyle(
            fontFamily: 'CormorantGaramond',
            fontSize: 17,
            color: Colors.white,
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: lightColorScheme.primaryContainer,
          foregroundColor: lightColorScheme.onPrimaryContainer,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: _lightRedCard,
          surfaceTintColor: lightColorScheme.primary,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: lightColorScheme.primaryContainer,
            foregroundColor: lightColorScheme.onPrimaryContainer,
            textStyle: const TextStyle(
              fontFamily: 'CormorantGaramond',
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
        chipTheme: ChipThemeData(
          selectedColor: lightColorScheme.primaryContainer,
          labelStyle: const TextStyle(fontFamily: 'CormorantGaramond'),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkColorScheme,
        brightness: Brightness.dark,
        fontFamily: 'CormorantGaramond',
        textTheme: baseTextTheme,
        tooltipTheme: const TooltipThemeData(
          textStyle: TextStyle(
            fontFamily: 'CormorantGaramond',
            fontSize: 17,
            color: Colors.black,
          ),
        ),
      ),
      themeMode: _themeMode,
      home: FeedPage(onThemeChanged: _toggleTheme, currentThemeMode: _themeMode),
    );
  }
}

class FeedPage extends StatefulWidget {
  final Function(bool) onThemeChanged;
  final ThemeMode currentThemeMode;

  const FeedPage({Key? key, required this.onThemeChanged, required this.currentThemeMode}) : super(key: key);

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> with WidgetsBindingObserver {
  static const int _minDwellMs = 3000; // 3-second lower bound
  static const int _maxStretchMs = 30000; // 30-second cap per centered stretch
  static const Duration _flushInterval = Duration(seconds: 150); // 2.5 minutes

  String _selectedFilter = 'Newest';
  final List<String> _filters = [
    'Newest',
    'Past 1 Hour',
    'Past 12 Hours',
    'Past Day',
    'Past Week',
    'Hall of Fame',
  ];

  final List<DocumentSnapshot> _posts = [];
  bool _isLoading = false;
  bool _hasMore = true;
  DocumentSnapshot? _lastDocument;
  final int _limit = 10;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _feedViewportKey = GlobalKey();
  final Map<String, GlobalKey> _postKeys = {};

  // Non-UI dwell tracking state (no setState on scroll/focus updates)
  String? _currentCenteredPostId;
  DateTime? _centeredSince;
  DateTime? _lastFocusSampleTime;
  final Map<String, int> _pendingViewMs = {};
  Timer? _flushTimer;
  Timer? _focusSampleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _fetchPosts();

    _flushTimer = Timer.periodic(_flushInterval, (_) {
      _finalizeCenteredStretch(DateTime.now(), restartIfStillCentered: true);
      _flushViewMetrics();
    });

    // Periodically sample so long stays on a single post respect the 30s cap
    _focusSampleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateCenteredPostFocus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _finalizeCenteredStretch(DateTime.now(), restartIfStillCentered: false);
      _flushViewMetrics();
    } else if (state == AppLifecycleState.resumed) {
      _updateCenteredPostFocus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
    _focusSampleTimer?.cancel();
    _finalizeCenteredStretch(DateTime.now(), restartIfStillCentered: false);
    _flushViewMetrics();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateCenteredPostFocus() {
    final now = DateTime.now();
    final viewportContext = _feedViewportKey.currentContext;
    if (viewportContext == null) {
      _finalizeCenteredStretch(now, restartIfStillCentered: false);
      return;
    }

    final viewportBox = viewportContext.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize || !viewportBox.attached) {
      return;
    }

    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    final viewportTop = viewportOrigin.dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    final viewportCenterY = viewportTop + (viewportBox.size.height / 2);

    String? bestPostId;
    double bestDistance = double.infinity;

    for (final doc in _posts) {
      final postId = doc.id;
      final key = _postKeys[postId];
      final postContext = key?.currentContext;
      if (postContext == null) continue;

      final renderObject = postContext.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize || !renderObject.attached) {
        continue;
      }

      final postTop = renderObject.localToGlobal(Offset.zero).dy;
      final postHeight = renderObject.size.height;
      final postBottom = postTop + postHeight;

      // Ignore cards completely outside the feed viewport
      if (postBottom <= viewportTop || postTop >= viewportBottom) {
        continue;
      }

      final postCenterY = postTop + (postHeight / 2);
      final distanceToCenter = (postCenterY - viewportCenterY).abs();

      if (distanceToCenter < bestDistance) {
        bestDistance = distanceToCenter;
        bestPostId = postId;
      }
    }

    if (bestPostId == _currentCenteredPostId) {
      if (_currentCenteredPostId != null && _centeredSince != null) {
        final rawElapsed = now.difference(_centeredSince!).inMilliseconds;
        // Enforce 30-second cap on the active continuous stretch
        if (rawElapsed >= _maxStretchMs) {
          _recordCappedStretch(_currentCenteredPostId!, _maxStretchMs);
          _centeredSince = now;
        }
      }
      _lastFocusSampleTime = now;
      return;
    }

    // Centered post changed: finalize previous stretch and start new one
    _finalizeCenteredStretch(now, restartIfStillCentered: false);
    _currentCenteredPostId = bestPostId;
    _centeredSince = bestPostId != null ? now : null;
    _lastFocusSampleTime = now;
  }

  void _finalizeCenteredStretch(DateTime now, {required bool restartIfStillCentered}) {
    final activeId = _currentCenteredPostId;
    final start = _centeredSince;
    if (activeId != null && start != null) {
      final elapsedMs = now.difference(start).inMilliseconds;
      final cappedMs = math.min(elapsedMs, _maxStretchMs);
      if (cappedMs >= _minDwellMs) {
        _pendingViewMs[activeId] = (_pendingViewMs[activeId] ?? 0) + cappedMs;
      }
    }

    if (restartIfStillCentered && activeId != null) {
      _centeredSince = now;
    } else {
      _currentCenteredPostId = null;
      _centeredSince = null;
    }
  }

  void _recordCappedStretch(String postId, int cappedMs) {
    if (cappedMs >= _minDwellMs) {
      _pendingViewMs[postId] = (_pendingViewMs[postId] ?? 0) + cappedMs;
    }
  }

  Future<void> _flushViewMetrics() async {
    if (_pendingViewMs.isEmpty) return;

    final batchEntries = Map<String, int>.from(_pendingViewMs);
    _pendingViewMs.clear();

    final batch = FirebaseFirestore.instance.batch();
    final postsCollection = FirebaseFirestore.instance.collection('posts');

    batchEntries.forEach((postId, ms) {
      final docRef = postsCollection.doc(postId);
      batch.update(docRef, {
        'viewTimeMs': FieldValue.increment(ms),
      });
    });

    try {
      await batch.commit();
    } catch (e) {
      // Restore unsent durations if flush fails so they aren't lost
      batchEntries.forEach((postId, ms) {
        _pendingViewMs[postId] = (_pendingViewMs[postId] ?? 0) + ms;
      });
      debugPrint('Error flushing view metrics: $e');
    }
  }

  void _onScroll() {
    _updateCenteredPostFocus();

    // Auto-load more posts when scrolling near the bottom (or approaching the 9th post)
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300) {
      if (!_isLoading && _hasMore) {
        _fetchPosts();
      }
    }
  }

  Future<void> _fetchPosts({bool reset = false}) async {
    if (reset) {
      _currentCenteredPostId = null;
      _centeredSince = null;
      _postKeys.clear();
      setState(() {
        _posts.clear();
        _lastDocument = null;
        _hasMore = true;
      });
    }

    if (_isLoading || !_hasMore) return;

    setState(() {
      _isLoading = true;
    });

    try {
      Query query = FirebaseFirestore.instance.collection('posts');
      final now = DateTime.now();

      if (_selectedFilter == 'Newest') {
        query = query.orderBy('timestamp', descending: true);
      } else if (_selectedFilter == 'Past 1 Hour') {
        final timeLimit = now.subtract(const Duration(hours: 1));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('viewTimeMs', descending: true);
      } else if (_selectedFilter == 'Past 12 Hours') {
        final timeLimit = now.subtract(const Duration(hours: 12));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('viewTimeMs', descending: true);
      } else if (_selectedFilter == 'Past Day') {
        final timeLimit = now.subtract(const Duration(days: 1));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('viewTimeMs', descending: true);
      } else if (_selectedFilter == 'Past Week') {
        final timeLimit = now.subtract(const Duration(days: 7));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('viewTimeMs', descending: true);
      } else if (_selectedFilter == 'Hall of Fame') {
        query = query.orderBy('viewTimeMs', descending: true);
      }

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      query = query.limit(_limit);
      final querySnapshot = await query.get();

      if (querySnapshot.docs.length < _limit) {
        _hasMore = false;
      }

      if (querySnapshot.docs.isNotEmpty) {
        _lastDocument = querySnapshot.docs.last;
        for (final doc in querySnapshot.docs) {
          _postKeys.putIfAbsent(doc.id, () => GlobalKey());
        }
        setState(() {
          _posts.addAll(querySnapshot.docs);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateCenteredPostFocus();
        });
      } else {
        setState(() {
          _hasMore = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching posts: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _onFilterChanged(String newFilter) async {
    _finalizeCenteredStretch(DateTime.now(), restartIfStillCentered: false);
    await _flushViewMetrics();
    setState(() {
      _selectedFilter = newFilter;
    });
    _fetchPosts(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = widget.currentThemeMode == ThemeMode.dark;
    final hasFooterSpinner = _hasMore;
    final itemCount = _posts.length + (hasFooterSpinner ? 1 : 0);

    return Scaffold(
      body: CustomScrollView(
        key: _feedViewportKey,
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            floating: false,
            pinned: false,
            snap: false,
            title: const Text(
              'Trending Now',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              IconButton(
                icon: Icon(isDarkMode ? Icons.wb_sunny : Icons.nightlight_round),
                onPressed: () => widget.onThemeChanged(!isDarkMode),
                tooltip: 'Toggle Theme',
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      _finalizeCenteredStretch(DateTime.now(), restartIfStillCentered: false);
                      await _flushViewMetrics();
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const MakePostPage()),
                      );
                      _fetchPosts(reset: true);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Make a Post'),
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(
                        fontFamily: 'CormorantGaramond',
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: _filters.map((filter) {
                      final isSelected = _selectedFilter == filter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: ChoiceChip(
                          label: Text(
                            filter,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          selected: isSelected,
                          onSelected: (selected) {
                            if (selected) {
                              _onFilterChanged(filter);
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(),
              ],
            ),
          ),
          if (_posts.isEmpty && _isLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_posts.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  'No posts found.',
                  style: TextStyle(fontSize: 20),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                    (context, index) {
                  if (index == _posts.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  final doc = _posts[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final text = data['text'] as String?;
                  final imageUrl = data['imageUrl'] as String?;
                  final caption = data['caption'] as String?;
                  final cardKey = _postKeys.putIfAbsent(doc.id, () => GlobalKey());

                  return Center(
                    key: cardKey,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (text != null && text.isNotEmpty) ...[
                                Text(
                                  text,
                                  style: const TextStyle(fontSize: 21),
                                ),
                              ],
                              if (imageUrl != null && imageUrl.isNotEmpty) ...[
                                if (text != null && text.isNotEmpty) const SizedBox(height: 12),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(maxHeight: 800),
                                    child: Image.network(
                                      imageUrl,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                                if (caption != null && caption.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    caption,
                                    style: const TextStyle(
                                      fontStyle: FontStyle.italic,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
                childCount: itemCount,
              ),
            ),
        ],
      ),
    );
  }
}