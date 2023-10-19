// ignore_for_file: prefer_single_quotes, sdk_version_since

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:exif/exif.dart';
import 'package:geocoder_offline/geocoder_offline.dart';
import 'package:path/path.dart' as path;

import 'country_codes.dart';

void main(List<String> args) async {
  final parser = ArgParser()..addOption("config", abbr: "c");
  final result = parser.parse(args);
  final configFile = result["config"];
  if (configFile == null || !File(configFile).existsSync()) {
    print("No config file");
    return;
  }

  final config = jsonDecode(File(configFile).readAsStringSync());
  final cameraRollFolder = config["camera_roll_folder"];
  if (!Directory(cameraRollFolder).existsSync()) {
    print("Config does not contain \"camera_roll_folder\"");
    return;
  }

  final cameraModelMappings = config["camera_model_folder_mappings"];
  if (cameraModelMappings is! Map) {
    print("Config does not contain a valid \"camera_model_folder_mappings\"");
    return;
  }

  final groupFolder = path.join(cameraRollFolder, config["group_by_location_folder"]);
  if (!Directory(groupFolder).existsSync()) {
    print("Config does not contain \"group_by_location_folder\"");
    return;
  }

  final csvFile = path.join(path.dirname(configFile), config["location_csv_file"]);
  if (!File(csvFile).existsSync()) {
    print("Config does not contain \"location_csv_file\"");
    return;
  }

  final globalCsvFile = path.join(path.dirname(configFile), config["global_location_csv_file"]);
  if (!File(globalCsvFile).existsSync()) {
    print("Config does not contain \"global_location_csv_file\"");
    return;
  }

  final testRun = config["test_run"];
  if (testRun == null) {
    print("Config does not contain \"test_run\"");
    return;
  }

  // await moveByMappings(cameraModelMappings);
  await groupByLocation(groupFolder, csvFile, globalCsvFile, testRun);
  // await printDateMismatch(groupFolder);

  print("Done");
}

Future<void> moveByMappings(Map<String, String> mappings) {
  throw Exception("Not implemented");
}

Future<void> groupByLocation(String groupFolder, String csvFile, String globalCsvFile, bool testRun) async {
  //* Initialize
  final geocoder = GeocodeData(
      File(csvFile).readAsStringSync(), //input string
      'name', // place name header
      'f3', // state/country header
      'latitude', // latitute header
      'longitude', // longitude header
      fieldDelimiter: '\t', // fields delimiter
      eol: '\n');
  final globalGeocoder = GeocodeData(
      File(globalCsvFile).readAsStringSync(), //input string
      'name', // place name header
      'f3', // state/country header
      'latitude', // latitute header
      'longitude', // longitude header
      fieldDelimiter: '\t', // fields delimiter
      eol: '\n');

  final namedLocation = <LocationInfo, List<File>>{};
  final files = Directory(groupFolder).listSync();

  var index = 0;
  var length = files.length;
  var progressMessage = "", previousProgressMessage = "";

  //* Group by year and location
  for (final file in files) {
    if (file is File) {
      final info = await ImageInfo.createFromFile(file);
      if (info != null) {
        final groupInfo = LocationInfo.createFromImageInfo(info, geocoder, globalGeocoder);
        namedLocation[groupInfo] ??= <File>[];
        namedLocation[groupInfo]?.add(file);

        progressMessage = (index * 100 ~/ length).toString() + "%";
        if (progressMessage != previousProgressMessage) {
          print(progressMessage);
        }
        previousProgressMessage = progressMessage;
      }
    }
    index++;
  }

  //* Reorder
  final entries = namedLocation.entries.toList()..sort((a, b) => b.value.length - a.value.length);
  for (final entry in entries) {
    print("${entry.key} (${entry.value.length} photos)");

    var folder = path.joinAll([groupFolder, ...entry.key.components]).replaceAll("/", "-");
    if (!Directory(folder).existsSync()) {
      if (!testRun) {
        Directory(folder).createSync(recursive: true);
      }
    }
    for (final file in entry.value) {
      final destination = path.join(folder, path.basename(file.path));
      if (!testRun) {
        file.renameSync(destination);
      }
    }
  }

  print("Found ${namedLocation.keys.length} locations");
}

Future<void> printDateMismatch(String groupFolder) async {
  final files = Directory(groupFolder).listSync(recursive: true);
  for (final file in files) {
    if (file is File) {
      final tags = await readExifFromFile(file);
      final exifDateTime = tags["EXIF DateTimeOriginal"], imageDateTime = tags["Image DateTime"];
      if (exifDateTime != null && imageDateTime != null && exifDateTime.toString() != imageDateTime.toString()) {
        print("Mismatch for ${path.basename(file.path)}, exif: $exifDateTime, imag: $imageDateTime");
      }
    }
  }
}

class ImageInfo {
  ImageInfo._(this.latitude, this.longitude, this.dateTime);

  static Future<ImageInfo?> createFromFile(File file) async {
    final tags = await readExifFromFile(file);
    final latitude = tags["GPS GPSLatitude"],
        longitude = tags["GPS GPSLongitude"],
        latitudeRef = tags["GPS GPSLatitudeRef"],
        longitudeRef = tags["GPS GPSLongitudeRef"],
        exifDateTime = tags["EXIF DateTimeOriginal"],
        imageDateTime = tags["Image DateTime"];
    final latitudeNum = _parseCoordinate(latitude?.toString(), latitudeRef?.toString().toUpperCase() == "S"),
        longitudeNum = _parseCoordinate(longitude?.toString(), longitudeRef?.toString().toUpperCase() == "W"),
        dateTime = _parseDateTime(exifDateTime?.toString()) ?? _parseDateTime(imageDateTime?.toString());
    if (dateTime != null) {
      return ImageInfo._(latitudeNum, longitudeNum, dateTime);
    }
    return null;
  }

  double? latitude;
  double? longitude;
  DateTime dateTime;

  //* home point
  // static final home = Location(46.280644, 15.056918);

  static double? _parseCoordinate(String? string, bool? invert) {
    if (string == null || invert == null) {
      return null;
    }

    final trimmedString = string.replaceAll("[", "").replaceAll("]", "").trim();
    final parts = trimmedString.split(",");
    if (parts.length != 3) {
      print("Bad coordinate: $string");
      return null;
    }
    final secondsParts = parts[2].split("/");
    if (secondsParts.isEmpty) {
      print("Bad coordinate: $string");
      return null;
    }

    final degrees = double.tryParse(parts[0]),
        minutes = double.tryParse(parts[1]),
        secondsWhole = double.tryParse(secondsParts[0]),
        secondsFloat = double.tryParse(secondsParts.elementAtOrNull(1) ?? "1");
    if (degrees == null || minutes == null || secondsWhole == null || secondsFloat == null) {
      print("Bad coordinate: $string");
      return null;
    }

    final coordinate = degrees + minutes / 60 + secondsWhole / secondsFloat / 3600;
    return coordinate * (invert ? -1 : 1);
  }

  static DateTime? _parseDateTime(String? string) {
    if (string == null) {
      return null;
    }

    final parts = string.split(" ");
    if (parts.length != 2) {
      print("Bad date: $string");
      return null;
    }
    final dateComponents = parts[0].split(":");
    if (dateComponents.length != 3) {
      print("Bad date: $string");
      return null;
    }
    final timeComponents = parts[1].split(":");
    if (timeComponents.length != 3) {
      print("Bad date: $string");
      return null;
    }

    final year = int.tryParse(dateComponents[0]), month = int.tryParse(dateComponents[1]), day = int.tryParse(dateComponents[2]);
    final hour = int.tryParse(timeComponents[0]), minute = int.tryParse(timeComponents[1]), second = int.tryParse(timeComponents[2]);
    if (year == null || month == null || day == null || hour == null || minute == null || second == null) {
      print("Bad date: $string");
      return null;
    }

    final dateTime = DateTime(year, month, day, hour, minute, second);
    return dateTime;
  }
}

class LocationInfo {
  LocationInfo._(this.year, [this.city, this.country]);

  final int year;
  final String? city;
  final String? country;

  static LocationInfo createFromImageInfo(ImageInfo info, GeocodeData geocoder, GeocodeData globalGeocoder) {
    if (info.latitude == null || info.longitude == null) {
      return LocationInfo._(info.dateTime.year);
    }

    final result = geocoder.search(info.latitude!, info.longitude!);
    var city = result.firstOrNull?.location.featureName ?? "Unknown";
    var country = result.firstOrNull?.location.state;
    if (country == "SI") {
      country = null;
    }

    if (country != null) {
      final globalResult = globalGeocoder.search(info.latitude!, info.longitude!);
      final globalCity = globalResult.firstOrNull?.location.featureName ?? "Unknown";
      final globalCountry = globalResult.firstOrNull?.location.state;
      if (globalCountry == country) {
        city = globalCity;
      }
      country = getCountry(country) ?? country;
    }

    return LocationInfo._(info.dateTime.year, city, country);
  }

  List<String> get components => [year.toString(), if (country != null) country!, if (city != null) city!];

  @override
  bool operator ==(Object other) => other is LocationInfo ? year == other.year && city == other.city && country == other.country : false;

  @override
  int get hashCode => year * (city?.hashCode ?? 1) * (country?.hashCode ?? 1);

  @override
  String toString() => "($year) ${country != null ? "${country!} - " : ""}${city ?? ""}".trim();
}
