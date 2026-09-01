import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/site.dart';
import 'plus_button.dart';

class DistanceInfoPanel extends StatefulWidget {
  final Position? user;
  final List<Site> sortedSites;
  // Triggers pipeline
  final Function(Site) onLaunch;
  // An index into the sorted sites list. Owned by the parent.
  final int currentIndex;
  final VoidCallback onNext;

  // TODO(prashanth@): collapse sortedSites and currentIndex into one and just
  // take "currentSite"
  const DistanceInfoPanel({
    super.key,
    required this.user,
    required this.sortedSites,
    required this.onLaunch,
    required this.currentIndex,
    required this.onNext,
  });

  @override
  State<DistanceInfoPanel> createState() => _DistanceInfoPanelState();
}

class _DistanceInfoPanelState extends State<DistanceInfoPanel> {
  /// Shrinks a long site id by keeping the year prefix and the trailing
  /// orientation token, replacing the middle with '…' so it stays visually
  /// distinct at a readable font size.
  String _middleElide(String text) {
    final headEnd = text.indexOf('_');
    final head = headEnd > 0
        ? text.substring(0, headEnd + 1)
        : text.substring(0, text.length < 6 ? text.length : 6);
    final tailStart = text.lastIndexOf('_');
    var tail = tailStart > headEnd
        ? text.substring(tailStart)
        : text.substring(text.length - (text.length < 4 ? text.length : 4));
    if (tail.length > 6) tail = tail.substring(tail.length - 4);
    if (text.length <= head.length + tail.length + 1) return text;
    return '$head…$tail';
  }

  @override
  void didUpdateWidget(covariant DistanceInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.user == null || widget.sortedSites.isEmpty) {
      return const SizedBox.shrink();
    }

    final current = widget.sortedSites[widget.currentIndex];
    final distance = Geolocator.distanceBetween(
      widget.user!.latitude,
      widget.user!.longitude,
      current.lat,
      current.lng,
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(32, 8, 32, 75),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(
          0xFF1A2024,
        ).withOpacity(0.9), // Dark grey panel background
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // --- Left column: site info ---
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Site',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 16,
                      color: Color(0xFF4FFD73),
                    ),
                    const SizedBox(width: 6),
                    // Auto-shrink site name to avoid overflow on long IDs
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _middleElide(current.id),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // --- Divider line between columns ---
          Container(
            width: 1,
            height: 35,
            color: Colors.white.withOpacity(0.15),
            margin: const EdgeInsets.symmetric(horizontal: 12),
          ),

          // --- Right column: distance info ---
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Distance',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.route, size: 16, color: Color(0xFF4FFD73)),
                        const SizedBox(width: 6),
                        Text(
                          distance >= 1000
                              ? '${(distance / 1000).toStringAsFixed(1)} km'
                              : '${distance.toStringAsFixed(0)} m',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // --- Forward button ---
          IconButton(
            icon: const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 18,
              color: Color(0xFF4FFD73),
            ),
            onPressed: () {
              widget.onNext();
            },
          ),

          // --- Plus button (pipeline launcher) ---
          PlusButton(
            enabled: widget.user != null,
            onPressed: () => widget.onLaunch(current),
          ),
        ],
      ),
    );
  }
}
