import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/services/press_to_talk_service.dart';
import 'package:provider/provider.dart';

/// Global Press-to-Talk overlay — shown above all pages when PTT is active.
/// Displays: top listening bar, center waveform circle, label, real-time transcript.
class PttOverlay extends StatelessWidget {
  const PttOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PressToTalkService>(
      builder: (context, ptt, _) {
        final isActive = ptt.state == PttSessionState.preparing ||
            ptt.state == PttSessionState.connecting ||
            ptt.state == PttSessionState.recording ||
            ptt.state == PttSessionState.processing;

        if (!isActive || !ptt.showOverlay) return const SizedBox.shrink();

        return _PttOverlayContent(
          state: ptt.state,
          partialText: ptt.partialText,
        );
      },
    );
  }
}

class _PttOverlayContent extends StatefulWidget {
  final PttSessionState state;
  final String partialText;

  const _PttOverlayContent({
    required this.state,
    required this.partialText,
  });

  @override
  State<_PttOverlayContent> createState() => _PttOverlayContentState();
}

class _PttOverlayContentState extends State<_PttOverlayContent> with TickerProviderStateMixin {
  late AnimationController _waveController;
  late AnimationController _fadeController;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _waveController.dispose();
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = widget.state == PttSessionState.recording;
    final isProcessing = widget.state == PttSessionState.processing;
    final mediaQuery = MediaQuery.of(context);

    return FadeTransition(
      opacity: _fadeController,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: const Color(0xBF000000), // black 75%
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 8),
                _buildTopBar(isRecording, isProcessing),
                const Spacer(),
                _buildWaveformCircle(isRecording),
                const SizedBox(height: 28),
                _buildLabel(isProcessing),
                const SizedBox(height: 16),
                if (widget.partialText.isNotEmpty) _buildTranscriptBubble(),
                const Spacer(),
                SizedBox(height: mediaQuery.padding.bottom + 80),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isRecording, bool isProcessing) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 60),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xD96C3AE0), // purple 85%
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Recording dot
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final alpha = isRecording ? (128 + 127 * math.sin(_pulseController.value * math.pi * 2)).round() : 128;
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Color.fromARGB(alpha, 255, 255, 255),
                  shape: BoxShape.circle,
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          _buildMiniWaveform(),
          const SizedBox(width: 10),
          Text(
            isProcessing ? S.of(context).pttProcessing : S.of(context).pttListening,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniWaveform() {
    return AnimatedBuilder(
      animation: _waveController,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (i) {
            final phase = _waveController.value * math.pi * 2 + i * 0.7;
            final height = 6.0 + 8.0 * math.sin(phase).abs();
            return Container(
              width: 2.5,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: const Color(0xE6FFFFFF), // white 90%
                borderRadius: BorderRadius.circular(1.5),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildWaveformCircle(bool isRecording) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulseScale = isRecording ? 1.0 + 0.05 * math.sin(_pulseController.value * math.pi * 2) : 1.0;
        return Transform.scale(
          scale: pulseScale,
          child: Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0x998B5CF6), // purple 60%
                width: 2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x337C3AED), // purple 20%
                  blurRadius: 40,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: Center(
              child: _buildCenterWaveform(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCenterWaveform() {
    return AnimatedBuilder(
      animation: _waveController,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(9, (i) {
            const centerIndex = 4;
            final distFromCenter = (i - centerIndex).abs();
            final maxHeight = 40.0 - distFromCenter * 5.0;
            const minHeight = 8.0;
            final phase = _waveController.value * math.pi * 2 + i * 0.5;
            final height = minHeight + (maxHeight - minHeight) * ((math.sin(phase) + 1) / 2);
            return Container(
              width: 3.5,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildLabel(bool isProcessing) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.mic,
              color: Color(0xE6FFFFFF), // white 90%
              size: 20,
            ),
            const SizedBox(width: 6),
            Text(
              S.of(context).pttVoiceCommand,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isProcessing ? S.of(context).pttTranscribing : S.of(context).pttReleaseToSend,
          style: const TextStyle(
            color: Color(0x99FFFFFF), // white 60%
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildTranscriptBubble() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x4D6C3AE0), // purple 30%
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0x668B5CF6), // purple 40%
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            S.of(context).pttRealTimeTranscript,
            style: const TextStyle(
              color: Color(0xFF8B5CF6),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.partialText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
