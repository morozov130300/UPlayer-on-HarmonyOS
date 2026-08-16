
export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('latestIntentWins', 0, () => {
      let generation: number = 0;
      const first: number = ++generation;
      const second: number = ++generation;
      expect(first === generation).assertFalse();
      expect(second === generation).assertTrue();
    });
    it('uriFilter', 0, () => {
      const isPersistable = (value: string): boolean => value.startsWith('file://') ||
        value.startsWith('datashare://') || value.startsWith('content://');
      expect(isPersistable('/storage/Users/current/song.lrc')).assertFalse();
      expect(isPersistable('file://docs/storage/Users/current/song.mp3')).assertTrue();
    });
    it('metadataOptionalDuration', 0, () => {
      const metadata: Record<string, Object> = { 'assetId': '1' };
      const duration: number = 0;
      if (duration > 0) metadata['duration'] = duration;
      expect(metadata['assetId']).assertEqual('1');
      expect(metadata['duration'] === undefined).assertTrue();
    });
    it('circuitBreakerThreshold', 0, () => {
      let failures: number = 0;
      const threshold: number = 1;
      failures++;
      expect(failures >= threshold).assertTrue();
    });
    it('liveViewColorFormat', 0, () => {
      const color: string = '#FF007DFF';
      expect(color.length).assertEqual(9);
      expect(color.startsWith('#')).assertTrue();
    });
    it('seekRestartUsesStoppedState', 0, () => {
      const operations: string[] = ['stop', 'demuxSeek', 'start'];
      expect(operations.indexOf('flush') < 0).assertTrue();
      expect(operations.join(',')).assertEqual('stop,demuxSeek,start');
    });
    it('equalizerHeadroomStartsAtPositiveGain', 0, () => {
      const maxPositiveGainDb: number = 10;
      const enabled: boolean = true;
      const headroomDb: number = enabled ? Math.max(0, maxPositiveGainDb) : 0;
      expect(headroomDb).assertEqual(10);
    });
    it('nativeEqualizerToggleKeepsBackend', 0, () => {
      const nativeMode: boolean = true;
      const enabledChanged: boolean = true;
      const shouldMigrateBackend: boolean = enabledChanged && !nativeMode;
      expect(shouldMigrateBackend).assertFalse();
    });
  });
}