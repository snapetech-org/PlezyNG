import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../i18n/strings.g.dart';
import '../../services/music/music_autoeq.dart';
import '../app_icon.dart';

Future<MusicHeadphonePreset?> pickMusicHeadphone(BuildContext context) =>
    showDialog<MusicHeadphonePreset>(context: context, builder: (_) => const _HeadphonePicker());

class _HeadphonePicker extends StatefulWidget {
  const _HeadphonePicker();
  @override
  State<_HeadphonePicker> createState() => _HeadphonePickerState();
}

class _HeadphonePickerState extends State<_HeadphonePicker> {
  late final _future = MusicAutoEq.load();
  String _query = '';
  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 650),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              if (constraints.maxHeight >= 400) ...[
                Text(t.musicTools.autoEqByJaakkoPasanen),
                const SizedBox(height: 8),
                Text(t.musicTools.eqApproximation),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      maxLength: 100,
                      decoration: InputDecoration(labelText: t.common.search, counterText: ''),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                  IconButton(
                    tooltip: t.common.cancel,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const AppIcon(Symbols.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FutureBuilder<List<MusicHeadphonePreset>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) return Text(t.musicExperience.error);
                    final presets = MusicAutoEq.search(snapshot.data ?? [], _query);
                    if (presets.isEmpty) return Text(t.common.notAvailable);
                    // The result list scrolls independently of the focused field.
                    // Caret visibility can no longer pull a result off-screen.
                    return ListView.builder(
                      itemCount: presets.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(presets[index].name),
                        onTap: () {
                          FocusScope.of(context).unfocus();
                          Navigator.of(context).pop(presets[index]);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
