import 'package:test/test.dart';
import 'package:yams_hub_gateway/yams_hub_gateway.dart';

void main() {
  group('PrivateLibraries.containsPath', () {
    const libs = PrivateLibraries(locations: ['/data/adult']);

    test('the folder and everything below it', () {
      expect(libs.containsPath('/data/adult'), isTrue);
      expect(libs.containsPath('/data/adult/'), isTrue);
      expect(libs.containsPath('/data/adult/x/y.mp4'), isTrue);
      expect(libs.containsPath('/DATA/Adult/y.mp4'), isTrue);
    });

    test('not a sibling with the same prefix', () {
      expect(libs.containsPath('/data/adult2/y.mp4'), isFalse);
      expect(libs.containsPath('/data/movies/adult/y.mp4'), isFalse);
      expect(libs.containsPath(null), isFalse);
      expect(libs.containsPath(''), isFalse);
    });

    test('trailing slashes and backslashes are normalised', () {
      expect(PrivateLibraries.normalisePath('/data/adult///'), '/data/adult');
      expect(
        PrivateLibraries.normalisePath(r'D:\Media\Adult'),
        'd:/media/adult',
      );
    });
  });
}
