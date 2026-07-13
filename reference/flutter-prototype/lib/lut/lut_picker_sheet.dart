import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'lut_library.dart';
import 'red_download_page.dart';

/// Outcome of [showLutPickerSheet].
sealed class LutPickerResult {
  const LutPickerResult();
}

/// The user chose a stored cube to apply.
class LutSelected extends LutPickerResult {
  const LutSelected(this.lut);

  /// The cube to apply.
  final StoredLut lut;
}

/// The user turned the LUT off.
class LutCleared extends LutPickerResult {
  const LutCleared();
}

/// Shows the LUT picker as a modal bottom sheet: download from RED, import a
/// file, turn the LUT off, or pick/delete a stored cube.
///
/// Resolves to a [LutPickerResult], or `null` if the sheet was dismissed.
Future<LutPickerResult?> showLutPickerSheet(
  BuildContext context,
  LutLibrary library, {
  String? currentFileName,
}) {
  return showModalBottomSheet<LutPickerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _LutPickerSheet(library: library, currentFileName: currentFileName),
  );
}

class _LutPickerSheet extends StatefulWidget {
  const _LutPickerSheet({required this.library, this.currentFileName});

  final LutLibrary library;
  final String? currentFileName;

  @override
  State<_LutPickerSheet> createState() => _LutPickerSheetState();
}

class _LutPickerSheetState extends State<_LutPickerSheet> {
  List<StoredLut> _luts = <StoredLut>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final luts = await widget.library.list();
    if (!mounted) return;
    setState(() {
      _luts = luts;
      _loading = false;
    });
  }

  Future<void> _downloadFromRed() async {
    final imported = await Navigator.of(context).push<List<StoredLut>>(
      MaterialPageRoute<List<StoredLut>>(
        builder: (_) => RedDownloadPage(library: widget.library),
      ),
    );
    if (!mounted) return;
    if (imported != null && imported.isNotEmpty) {
      final byDefault = pickDefaultRec709(imported) ?? imported.first;
      Navigator.of(context).pop(LutSelected(byDefault));
      return;
    }
    await _refresh();
  }

  Future<void> _importFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (!mounted || result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    try {
      final lut = await widget.library.importCubeFile(path);
      if (!mounted) return;
      Navigator.of(context).pop(LutSelected(lut));
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  Future<void> _delete(StoredLut lut) async {
    await widget.library.delete(lut);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'LUTs',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _downloadFromRed,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download from RED'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _importFile,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Import file'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(const LutCleared()),
                    icon: const Icon(Icons.block, size: 18),
                    label: const Text('None'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_luts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No LUTs yet. Download from RED or import a .cube file.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _luts.length,
      itemBuilder: (context, i) {
        final lut = _luts[i];
        final selected = lut.fileName == widget.currentFileName;
        return ListTile(
          leading: Icon(
            selected ? Icons.check_circle : Icons.photo_filter,
            color: selected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(lut.displayName, maxLines: 2),
          subtitle: Text(lut.category),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: () => _delete(lut),
          ),
          onTap: () => Navigator.of(context).pop(LutSelected(lut)),
        );
      },
    );
  }
}
