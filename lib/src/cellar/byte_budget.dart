import 'package:cellar/src/cellar/eviction_policy.dart';

/// A byte cap shared by several partitions.
///
/// A partition's own `Lifecycle.maxBytes` caps that partition. A budget caps the
/// partitions together: "these may hold 1 GiB between them", however they split it.
/// Each partition's own rules run first, so a partition can still be held to a
/// smaller share; the budget then evicts across the members, in its
/// [evictionPolicy] order, until their total is under [maxBytes].
///
/// ```dart
/// Cellar(
///   name: 'my_app',
///   partitions: {
///     'files': PartitionConfig(lifecycle: Lifecycle.cache(maxBytes: 672 << 20)),
///     'avatars': PartitionConfig(lifecycle: Lifecycle.cache(maxBytes: 64 << 20)),
///   },
///   budgets: {
///     'cache': ByteBudget(
///       maxBytes: 1 << 30,
///       partitions: {'files', 'avatars'},
///       evictionPolicy: EvictionPolicy.leastRecentlyUsed,
///     ),
///   },
/// );
/// ```
///
/// Everything a member's `Lifecycle` says about evicting still applies when the
/// budget does it: `canEvict` keeps an object, `evictionGuard` wraps the delete,
/// and `onEvicted` is told (with [EvictionReason.budget]). A member needs no
/// lifecycle of its own to be in a budget.
class ByteBudget {
  /// A cap of [maxBytes] over [partitions], run every [runInterval].
  const ByteBudget({
    required this.maxBytes,
    required this.partitions,
    this.evictionPolicy = EvictionPolicy.oldestWritten,
    this.runInterval = const Duration(hours: 1),
  });

  /// The most bytes the member partitions hold between them. Must be positive.
  final int maxBytes;

  /// The partitions that share the budget. Each must exist, and a partition is in at
  /// most one budget.
  final Set<String> partitions;

  /// The order in which objects are evicted across the members when the total is
  /// over [maxBytes], and when `Cellar.makeRoom` frees space. Default
  /// [EvictionPolicy.oldestWritten].
  final EvictionPolicy evictionPolicy;

  /// How often the budget is checked, with the partitions' own rules (a single timer
  /// runs at the shortest interval anywhere in the cellar). Default one hour.
  final Duration runInterval;
}
