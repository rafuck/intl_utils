import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as path;

import 'package:intl_translation/extract_messages.dart';
import 'package:intl_translation/generate_localized.dart';
import 'package:intl_translation/src/icu_parser.dart';
import 'package:intl_translation/src/intl_message.dart';

import 'package:intl_utils/src/utils.dart';

class IntlTranslationHelper {
  final pluralAndGenderParser = IcuParser().message;
  final plainParser = IcuParser().nonIcuMessage;
  final JsonCodec jsonDecoder = JsonCodec();

  final MessageExtraction extraction = MessageExtraction();
  final MessageGeneration generation = MessageGeneration();
  final Map<String, List<MainMessage>> messages = {}; // Track of all processed messages, keyed by message name

  IntlTranslationHelper() {
    extraction.suppressWarnings = true;
    generation.useDeferredLoading = false;
    generation.generatedFilePrefix = '';
  }

  void generateFromArb(String outputDir, List<String> dartFiles, List<String> arbFiles) {
    var allMessages = dartFiles.map((file) => extraction.parseFile(File(file)));
    for (var messageMap in allMessages) {
      messageMap.forEach((key, value) => messages.putIfAbsent(key, () => []).add(value));
    }

    var messagesByLocale = <String, List<Map>>{};
    // Note: To group messages by locale, we eagerly read all data, which might cause a memory issue for large projects
    for (var arbFile in arbFiles) {
      _loadData(arbFile, messagesByLocale);
    }
    messagesByLocale.forEach((locale, data) {
      _generateLocaleFile(locale, data, outputDir);
    });

    var mainImportFile = File(path.join(outputDir, '${generation.generatedFilePrefix}messages_all.dart'));
    mainImportFile.writeAsStringSync(generation.generateMainImportFile());
  }

  void _loadData(String filename, Map<String, List<Map>> messagesByLocale) {
    var file = File(filename);
    var src = file.readAsStringSync();
    var data = jsonDecoder.decode(src);
    var locale = data['@@locale'] ?? data['_locale'];
    if (locale == null) {
      // Get the locale from the end of the file name. This assumes that the file
      // name doesn't contain any underscores except to begin the language tag
      // and to separate language from country. Otherwise we can't tell if
      // my_file_fr.arb is locale "fr" or "file_fr".
      var name = path.basenameWithoutExtension(file.path);
      locale = name.split('_').skip(1).join('_');
      info("No @@locale or _locale field found in $name, assuming '$locale' based on the file name.");
    }
    messagesByLocale.putIfAbsent(locale, () => []).add(data);
    generation.allLocales.add(locale);
  }

  void _generateLocaleFile(String locale, List<Map> localeData, String targetDir) {
    var translations = <TranslatedMessage>[];
    for (var jsonTranslations in localeData) {
      jsonTranslations.forEach((id, messageData) {
        TranslatedMessage message = _recreateIntlObjects(id, messageData);
        if (message != null) {
          translations.add(message);
        }
      });
    }
    generation.generateIndividualMessageFile(locale, translations, targetDir);
  }

  /// Regenerate the original IntlMessage objects from the given [data]. For
  /// things that are messages, we expect [id] not to start with "@" and
  /// [data] to be a String. For metadata we expect [id] to start with "@"
  /// and [data] to be a Map or null. For metadata we return null.
  BasicTranslatedMessage _recreateIntlObjects(String id, data) {
    if (id.startsWith('@')) return null;
    if (data == null) return null;
    var parsed = pluralAndGenderParser.parse(data).value;
    if (parsed is LiteralString && parsed.string.isEmpty) {
      parsed = plainParser.parse(data).value;
    }
    return BasicTranslatedMessage(id, parsed, messages);
  }
}

/// A TranslatedMessage that just uses the name as the id and knows how to look up its original messages in our [messages].
class BasicTranslatedMessage extends TranslatedMessage {
  Map<String, List<MainMessage>> messages;

  BasicTranslatedMessage(String name, translated, this.messages) : super(name, translated);

  @override
  List<MainMessage> get originalMessages =>
      (super.originalMessages == null) ? _findOriginals() : super.originalMessages;

  // We know that our [id] is the name of the message, which is used as the key in [messages].
  List<MainMessage> _findOriginals() => originalMessages = messages[id];
}
