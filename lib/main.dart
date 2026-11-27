import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'make_post.dart';

const String _darkModePrefKey = 'is_dark_mode';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final bool initialDarkMode = prefs.getBool(_darkModePrefKey) ?? false;
  runApp(TrendingNowApp(initialDarkMode: initialDarkMode));
}

class TrendingNowApp extends StatefulWidget {
  final bool initialDarkMode;

  const TrendingNowApp({Key? key, this.initialDarkMode = false}) : super(key: key);

  @override
  State<TrendingNowApp> createState() => _TrendingNowAppState();
}

class _TrendingNowAppState extends State<TrendingNowApp> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> _toggleTheme(bool isDark) async {
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModePrefKey, isDark);
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
  static const int _lingerThresholdMs = 3500; // 3.5-second linger threshold
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
  int _fetchGeneration = 0;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _feedViewportKey = GlobalKey();
  final Map<String, GlobalKey> _postKeys = {};

  // Session-level linger tracking state (no setState on scroll/focus updates)
  String? _currentCenteredPostId;
  DateTime? _centeredSince;
  final Set<String> _lingerRecordedInSession = <String>{};
  final Map<String, int> _pendingLingerCounts = <String, int>{};
  Timer? _flushTimer;
  Timer? _focusSampleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _fetchPosts();

    _flushTimer = Timer.periodic(_flushInterval, (_) {
      _evaluateCenteredPostLinger(DateTime.now());
      _flushLingerMetrics();
    });

    // Periodically evaluate so lingering past 3.5s registers without waiting for scroll
    _focusSampleTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _updateCenteredPostFocus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _evaluateCenteredPostLinger(DateTime.now());
      _flushLingerMetrics();
    } else if (state == AppLifecycleState.resumed) {
      _updateCenteredPostFocus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
    _focusSampleTimer?.cancel();
    _evaluateCenteredPostLinger(DateTime.now());
    _flushLingerMetrics();
    _scrollController.dispose();
    super.dispose();
  }

  void _evaluateCenteredPostLinger(DateTime now) {
    final activeId = _currentCenteredPostId;
    final start = _centeredSince;
    if (activeId == null || start == null) return;
    if (_lingerRecordedInSession.contains(activeId)) return;

    final elapsedMs = now.difference(start).inMilliseconds;
    if (elapsedMs >= _lingerThresholdMs) {
      _lingerRecordedInSession.add(activeId);
      _pendingLingerCounts[activeId] = (_pendingLingerCounts[activeId] ?? 0) + 1;
    }
  }

  void _updateCenteredPostFocus() {
    final now = DateTime.now();
    _evaluateCenteredPostLinger(now);

    final viewportContext = _feedViewportKey.currentContext;
    if (viewportContext == null) {
      _currentCenteredPostId = null;
      _centeredSince = null;
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
      return;
    }

    _currentCenteredPostId = bestPostId;
    _centeredSince = bestPostId != null ? now : null;
  }

  Future<void> _flushLingerMetrics() async {
    if (_pendingLingerCounts.isEmpty) return;

    final batchEntries = Map<String, int>.from(_pendingLingerCounts);
    _pendingLingerCounts.clear();

    final batch = FirebaseFirestore.instance.batch();
    final postsCollection = FirebaseFirestore.instance.collection('posts');

    batchEntries.forEach((postId, count) {
      final docRef = postsCollection.doc(postId);
      batch.update(docRef, {
        'lingerCount': FieldValue.increment(count),
      });
    });

    try {
      await batch.commit();
    } catch (e) {
      // Restore unsent counts if flush fails so they aren't lost
      batchEntries.forEach((postId, count) {
        _pendingLingerCounts[postId] = (_pendingLingerCounts[postId] ?? 0) + count;
      });
      debugPrint('Error flushing linger metrics: $e');
    }
  }

  void _onScroll() {
    _updateCenteredPostFocus();

    // Auto-load more posts when scrolling near the bottom
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300) {
      if (!_isLoading && _hasMore) {
        _fetchPosts();
      }
    }
  }

  Future<void> _fetchPosts({bool reset = false}) async {
    if (reset) {
      _fetchGeneration++;
      _currentCenteredPostId = null;
      _centeredSince = null;
      _postKeys.clear();
      setState(() {
        _posts.clear();
        _lastDocument = null;
        _hasMore = true;
        _isLoading = false;
      });
    }

    if (_isLoading || !_hasMore) return;

    final int generation = _fetchGeneration;
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
            .orderBy('lingerCount', descending: true);
      } else if (_selectedFilter == 'Past 12 Hours') {
        final timeLimit = now.subtract(const Duration(hours: 12));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('lingerCount', descending: true);
      } else if (_selectedFilter == 'Past Day') {
        final timeLimit = now.subtract(const Duration(days: 1));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('lingerCount', descending: true);
      } else if (_selectedFilter == 'Past Week') {
        final timeLimit = now.subtract(const Duration(days: 7));
        query = query
            .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit))
            .orderBy('lingerCount', descending: true);
      } else if (_selectedFilter == 'Hall of Fame') {
        query = query.orderBy('lingerCount', descending: true);
      }

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      query = query.limit(_limit);
      final querySnapshot = await query.get();
      if (!mounted || generation != _fetchGeneration) return;

      final bool reachedEnd = querySnapshot.docs.length < _limit;

      if (querySnapshot.docs.isNotEmpty) {
        _lastDocument = querySnapshot.docs.last;
        for (final doc in querySnapshot.docs) {
          _postKeys.putIfAbsent(doc.id, () => GlobalKey());
        }
        setState(() {
          _posts.addAll(querySnapshot.docs);
          _hasMore = !reachedEnd;
          _isLoading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateCenteredPostFocus();
        });
      } else {
        setState(() {
          _hasMore = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching posts: $e');
      if (mounted && generation == _fetchGeneration) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _onFilterChanged(String newFilter) async {
    _evaluateCenteredPostLinger(DateTime.now());
    _currentCenteredPostId = null;
    _centeredSince = null;
    await _flushLingerMetrics();
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
                      _evaluateCenteredPostLinger(DateTime.now());
                      _currentCenteredPostId = null;
                      _centeredSince = null;
                      await _flushLingerMetrics();
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
                  final cardKey = _postKeys.putIfAbsent(doc.id, () => GlobalKey());

                  return Center(
                    key: cardKey,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: text != null && text.isNotEmpty
                              ? Text(
                            text,
                            style: const TextStyle(fontSize: 21),
                          )
                              : const SizedBox.shrink(),
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