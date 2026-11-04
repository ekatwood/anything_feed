import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'human_test.dart';
import 'make_post.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform, // Configure for your Firebase project
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
    return MaterialApp(
      title: 'Trending Now',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
        fontFamily: 'CormorantGaramond'
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        fontFamily: 'CormorantGaramond'
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

class _FeedPageState extends State<FeedPage> {
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

  @override
  void initState() {
    super.initState();
    _fetchPosts();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Auto-load more posts when scrolling near the bottom (or approaching the 9th post)
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300) {
      if (!_isLoading && _hasMore) {
        _fetchPosts();
      }
    }
  }

  Future<void> _fetchPosts({bool reset = false}) async {
    if (reset) {
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

      // Apply time frame or sorting filters
      if (_selectedFilter == 'Newest') {
        query = query.orderBy('timestamp', descending: true);
      } else if (_selectedFilter == 'Past 1 Hour') {
        final timeLimit = now.subtract(const Duration(hours: 1));
        query = query.where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit)).orderBy('timestamp', descending: true);
      } else if (_selectedFilter == 'Past 12 Hours') {
        final timeLimit = now.subtract(const Duration(hours: 12));
        query = query.where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit)).orderBy('timestamp', descending: true);
      } else if (_selectedFilter == 'Past Day') {
        final timeLimit = now.subtract(const Duration(days: 1));
        query = query.where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit)).orderBy('timestamp', descending: true);
      } else if (_selectedFilter == 'Past Week') {
        final timeLimit = now.subtract(const Duration(days: 7));
        query = query.where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(timeLimit)).orderBy('timestamp', descending: true);
      } else if (_selectedFilter == 'Hall of Fame') {
        query = query.orderBy('upvotes', descending: true);
      }

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      query = query.limit(_limit);
      QuerySnapshot querySnapshot = await query.get();

      if (querySnapshot.docs.length < _limit) {
        _hasMore = false;
      }

      if (querySnapshot.docs.isNotEmpty) {
        _lastDocument = querySnapshot.docs.last;
        setState(() {
          _posts.addAll(querySnapshot.docs);
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

  void _onFilterChanged(String newFilter) {
    setState(() {
      _selectedFilter = newFilter;
    });
    _fetchPosts(reset: true);
  }

  Future<void> _handleUpvote(DocumentReference postRef, int currentUpvotes) async {
    bool verified = await HumanTestDialog.isVerified();
    if (!verified) {
      showDialog(
        context: context,
        builder: (context) => HumanTestDialog(
          onSuccess: () {
            _executeUpvote(postRef, currentUpvotes);
          },
        ),
      );
    } else {
      _executeUpvote(postRef, currentUpvotes);
    }
  }

  Future<void> _executeUpvote(DocumentReference postRef, int currentUpvotes) async {
    await postRef.update({'upvotes': currentUpvotes + 1});
    _fetchPosts(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = widget.currentThemeMode == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trending Now'),
        actions: [
          IconButton(
            icon: Icon(isDarkMode ? Icons.wb_sunny : Icons.nightlight_round),
            onPressed: () => widget.onThemeChanged(!isDarkMode),
            tooltip: 'Toggle Theme',
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          // Centered 'Plus' button to make a post
          Center(
            child: ElevatedButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const MakePostPage()),
                );
                _fetchPosts(reset: true);
              },
              icon: const Icon(Icons.add),
              label: const Text('Make a Post'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Time frame filter selector
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: _filters.map((filter) {
                bool isSelected = _selectedFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(filter),
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
          // Feed of posts
          Expanded(
            child: _posts.isEmpty && _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _posts.isEmpty
                ? const Center(child: Text('No posts found.'))
                : ListView.builder(
              controller: _scrollController,
              itemCount: _posts.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
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
                final upvotes = data['upvotes'] as int? ?? 0;

                return Center(
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
                                style: const TextStyle(fontSize: 16),
                              ),
                            ],
                            if (imageUrl != null && imageUrl.isNotEmpty) ...[
                              if (text != null && text.isNotEmpty) const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  imageUrl,
                                  height: 250,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
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
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.thumb_up_alt_outlined),
                                  color: Colors.blue,
                                  onPressed: () => _handleUpvote(doc.reference, upvotes),
                                ),
                                Text(
                                  '$upvotes',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}