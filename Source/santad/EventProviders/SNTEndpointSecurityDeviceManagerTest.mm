/// Copyright 2022 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import <DiskArbitration/DiskArbitration.h>
#include <EndpointSecurity/EndpointSecurity.h>
#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>
#import <bsm/libbsm.h>
#import <dispatch/dispatch.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include <sys/mount.h>
#include <cstddef>

#include <memory>
#include <set>

#import "Source/common/SNTCommonEnums.h"
#import "Source/common/SNTConfigurator.h"
#import "Source/common/SNTDeviceEvent.h"
#include "Source/common/TestUtils.h"
#include "Source/santad/EventProviders/AuthResultCache.h"
#import "Source/santad/EventProviders/DiskArbitrationTestUtil.h"
#include "Source/santad/EventProviders/EndpointSecurity/Message.h"
#include "Source/santad/EventProviders/EndpointSecurity/MockEndpointSecurityAPI.h"
#import "Source/santad/EventProviders/SNTEndpointSecurityClient.h"
#import "Source/santad/EventProviders/SNTEndpointSecurityDeviceManager.h"
#include "Source/santad/Metrics.h"

using santa::AuthResultCache;
using santa::EventDisposition;
using santa::FlushCacheMode;
using santa::FlushCacheReason;
using santa::Message;

class MockAuthResultCache : public AuthResultCache {
 public:
  using AuthResultCache::AuthResultCache;

  MOCK_METHOD(void, FlushCache, (FlushCacheMode mode, FlushCacheReason reason));
};

@interface SNTEndpointSecurityClient (Testing)
@property(nonatomic) double defaultBudget;
@property(nonatomic) int64_t minAllowedHeadroom;
@property(nonatomic) int64_t maxAllowedHeadroom;
@end

@interface SNTEndpointSecurityDeviceManager (Testing)
- (instancetype)init;
- (void)logDiskAppeared:(NSDictionary *)props;
- (BOOL)shouldOperateOnDisk:(DADiskRef)disk;
- (void)performStartupTasks:(SNTDeviceManagerStartupPreferences)startupPrefs;
- (uint32_t)updatedMountFlags:(struct statfs *)sfs;
@end

@interface SNTEndpointSecurityDeviceManagerTest : XCTestCase
@property id mockConfigurator;
@property MockDiskArbitration *mockDA;
@property MockMounts *mockMounts;
@end

@implementation SNTEndpointSecurityDeviceManagerTest

- (void)setUp {
  [super setUp];

  self.mockConfigurator = OCMClassMock([SNTConfigurator class]);
  OCMStub([self.mockConfigurator configurator]).andReturn(self.mockConfigurator);
  OCMStub([self.mockConfigurator eventLogType]).andReturn(-1);

  self.mockDA = [MockDiskArbitration mockDiskArbitration];
  [self.mockDA reset];

  self.mockMounts = [MockMounts mockMounts];
  [self.mockMounts reset];

  fclose(stdout);
}

- (void)triggerTestMountEvent:(es_event_type_t)eventType
            diskInfoOverrides:(NSDictionary *)diskInfo
           expectedAuthResult:(es_auth_result_t)expectedAuthResult
           deviceManagerSetup:(void (^)(SNTEndpointSecurityDeviceManager *))setupDMCallback {
  struct statfs fs = {0};
  NSString *test_mntfromname = @"/dev/disk2s1";
  NSString *test_mntonname = @"/Volumes/KATE'S 4G";

  strncpy(fs.f_mntfromname, [test_mntfromname UTF8String], sizeof(fs.f_mntfromname));
  strncpy(fs.f_mntonname, [test_mntonname UTF8String], sizeof(fs.f_mntonname));

  MockDADisk *disk = [[MockDADisk alloc] init];
  disk.diskDescription = @{
    (__bridge NSString *)kDADiskDescriptionDeviceProtocolKey : @"USB",
    (__bridge NSString *)kDADiskDescriptionMediaRemovableKey : @YES,
    @"DAVolumeMountable" : @YES,
    @"DAVolumePath" : test_mntonname,
    @"DADeviceModel" : @"Some device model",
    @"DADevicePath" : test_mntonname,
    @"DADeviceVendor" : @"Some vendor",
    @"DAAppearanceTime" : @0,
    @"DAMediaBSDName" : test_mntfromname,
  };

  if (diskInfo != nil) {
    NSMutableDictionary *mergedDiskDescription = [disk.diskDescription mutableCopy];
    for (NSString *key in diskInfo) {
      mergedDiskDescription[key] = diskInfo[key];
    }
    disk.diskDescription = (NSDictionary *)mergedDiskDescription;
  }

  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();
  mockESApi->SetExpectationsESNewClient();

  SNTEndpointSecurityDeviceManager *deviceManager = [[SNTEndpointSecurityDeviceManager alloc]
           initWithESAPI:mockESApi
                 metrics:nullptr
                  logger:nullptr
         authResultCache:nullptr
           blockUSBMount:false
          remountUSBMode:nil
      startupPreferences:SNTDeviceManagerStartupPreferencesNone];

  setupDMCallback(deviceManager);

  // Stub the log method since a mock `Logger` object isn't used.
  id partialDeviceManager = OCMPartialMock(deviceManager);
  OCMStub([partialDeviceManager logDiskAppeared:OCMOCK_ANY]);

  [self.mockDA insert:disk];

  es_file_t file = MakeESFile("foo");
  es_process_t proc = MakeESProcess(&file);

  // This test is sensitive to ~1s processing budget.
  // Set a 5s headroom and 6s deadline
  deviceManager.minAllowedHeadroom = 5 * NSEC_PER_SEC;
  deviceManager.maxAllowedHeadroom = 5 * NSEC_PER_SEC;
  es_message_t esMsg = MakeESMessage(eventType, &proc, ActionType::Auth, 6000);

  dispatch_semaphore_t semaMetrics = dispatch_semaphore_create(0);

  __block int retainCount = 0;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  EXPECT_CALL(*mockESApi, ReleaseMessage).WillRepeatedly(^{
    if (retainCount == 0) {
      XCTFail(@"Under retain!");
    }
    retainCount--;
    if (retainCount == 0) {
      dispatch_semaphore_signal(sema);
    }
  });
  EXPECT_CALL(*mockESApi, RetainMessage).WillRepeatedly(^{
    retainCount++;
  });

  if (eventType == ES_EVENT_TYPE_AUTH_MOUNT) {
    esMsg.event.mount.statfs = &fs;
  } else if (eventType == ES_EVENT_TYPE_AUTH_REMOUNT) {
    esMsg.event.remount.statfs = &fs;
  } else {
    // Programming error. Fail the test.
    XCTFail(@"Unhandled event type in test: %d", eventType);
  }

  XCTestExpectation *mountExpectation =
      [self expectationWithDescription:@"Wait for response from ES"];

  EXPECT_CALL(*mockESApi, RespondAuthResult(testing::_, testing::_, expectedAuthResult, false))
      .WillOnce(testing::InvokeWithoutArgs(^bool {
        [mountExpectation fulfill];
        return true;
      }));

  [deviceManager handleMessage:Message(mockESApi, &esMsg)
            recordEventMetrics:^(EventDisposition d) {
              XCTAssertEqual(d, deviceManager.blockUSBMount ? EventDisposition::kProcessed
                                                            : EventDisposition::kDropped);
              dispatch_semaphore_signal(semaMetrics);
            }];

  [self waitForExpectations:@[ mountExpectation ] timeout:60.0];

  XCTAssertSemaTrue(semaMetrics, 5, "Metrics not recorded within expected window");
  XCTAssertSemaTrue(sema, 5, "Failed waiting for message to be processed...");

  [partialDeviceManager stopMocking];
  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
}

- (void)testUSBBlockDisabled {
  [self triggerTestMountEvent:ES_EVENT_TYPE_AUTH_MOUNT
            diskInfoOverrides:nil
           expectedAuthResult:ES_AUTH_RESULT_ALLOW
           deviceManagerSetup:^(SNTEndpointSecurityDeviceManager *dm) {
             dm.blockUSBMount = NO;
           }];
}

- (void)testRemount {
  NSArray *wantRemountArgs = @[ @"noexec", @"rdonly" ];

  XCTestExpectation *expectation =
      [self expectationWithDescription:
                @"Wait for SNTEndpointSecurityDeviceManager's blockCallback to trigger"];

  __block NSString *gotmntonname, *gotmntfromname;
  __block NSArray<NSString *> *gotRemountedArgs;

  [self triggerTestMountEvent:ES_EVENT_TYPE_AUTH_MOUNT
            diskInfoOverrides:nil
           expectedAuthResult:ES_AUTH_RESULT_DENY
           deviceManagerSetup:^(SNTEndpointSecurityDeviceManager *dm) {
             dm.blockUSBMount = YES;
             dm.remountArgs = wantRemountArgs;

             dm.deviceBlockCallback = ^(SNTDeviceEvent *event) {
               gotRemountedArgs = event.remountArgs;
               gotmntonname = event.mntonname;
               gotmntfromname = event.mntfromname;
               [expectation fulfill];
             };
           }];

  XCTAssertEqual(self.mockDA.insertedDevices.count, 1);
  XCTAssertTrue([self.mockDA.insertedDevices allValues][0].wasMounted);

  [self waitForExpectations:@[ expectation ] timeout:60.0];

  XCTAssertEqualObjects(gotRemountedArgs, wantRemountArgs);
  XCTAssertEqualObjects(gotmntonname, @"/Volumes/KATE'S 4G");
  XCTAssertEqualObjects(gotmntfromname, @"/dev/disk2s1");
}

- (void)testBlockNoRemount {
  XCTestExpectation *expectation =
      [self expectationWithDescription:
                @"Wait for SNTEndpointSecurityDeviceManager's blockCallback to trigger"];

  __block NSString *gotmntonname, *gotmntfromname;
  __block NSArray<NSString *> *gotRemountedArgs;

  [self triggerTestMountEvent:ES_EVENT_TYPE_AUTH_MOUNT
            diskInfoOverrides:nil
           expectedAuthResult:ES_AUTH_RESULT_DENY
           deviceManagerSetup:^(SNTEndpointSecurityDeviceManager *dm) {
             dm.blockUSBMount = YES;

             dm.deviceBlockCallback = ^(SNTDeviceEvent *event) {
               gotRemountedArgs = event.remountArgs;
               gotmntonname = event.mntonname;
               gotmntfromname = event.mntfromname;
               [expectation fulfill];
             };
           }];

  [self waitForExpectations:@[ expectation ] timeout:60.0];

  XCTAssertNil(gotRemountedArgs);
  XCTAssertEqualObjects(gotmntonname, @"/Volumes/KATE'S 4G");
  XCTAssertEqualObjects(gotmntfromname, @"/dev/disk2s1");
}

- (void)testEnsureRemountsCannotChangePerms {
  NSArray *wantRemountArgs = @[ @"noexec", @"rdonly" ];

  XCTestExpectation *expectation =
      [self expectationWithDescription:
                @"Wait for SNTEndpointSecurityDeviceManager's blockCallback to trigger"];

  __block NSString *gotmntonname, *gotmntfromname;
  __block NSArray<NSString *> *gotRemountedArgs;

  [self triggerTestMountEvent:ES_EVENT_TYPE_AUTH_MOUNT
            diskInfoOverrides:nil
           expectedAuthResult:ES_AUTH_RESULT_DENY
           deviceManagerSetup:^(SNTEndpointSecurityDeviceManager *dm) {
             dm.blockUSBMount = YES;
             dm.remountArgs = wantRemountArgs;

             dm.deviceBlockCallback = ^(SNTDeviceEvent *event) {
               gotRemountedArgs = event.remountArgs;
               gotmntonname = event.mntonname;
               gotmntfromname = event.mntfromname;
               [expectation fulfill];
             };
           }];

  XCTAssertEqual(self.mockDA.insertedDevices.count, 1);
  XCTAssertTrue([self.mockDA.insertedDevices allValues][0].wasMounted);

  [self waitForExpectations:@[ expectation ] timeout:10.0];

  XCTAssertEqualObjects(gotRemountedArgs, wantRemountArgs);
  XCTAssertEqualObjects(gotmntonname, @"/Volumes/KATE'S 4G");
  XCTAssertEqualObjects(gotmntfromname, @"/dev/disk2s1");
}

- (void)testEnsureDMGsDoNotPrompt {
  NSArray *wantRemountArgs = @[ @"noexec", @"rdonly" ];
  NSDictionary *diskInfo = @{
    (__bridge NSString *)kDADiskDescriptionDeviceProtocolKey : @"Virtual Interface",
    (__bridge NSString *)kDADiskDescriptionDeviceModelKey : @"Disk Image",
    (__bridge NSString *)kDADiskDescriptionMediaNameKey : @"disk image",
  };

  [self triggerTestMountEvent:ES_EVENT_TYPE_AUTH_MOUNT
            diskInfoOverrides:diskInfo
           expectedAuthResult:ES_AUTH_RESULT_ALLOW
           deviceManagerSetup:^(SNTEndpointSecurityDeviceManager *dm) {
             dm.blockUSBMount = YES;
             dm.remountArgs = wantRemountArgs;

             dm.deviceBlockCallback = ^(SNTDeviceEvent *event) {
               XCTFail(@"Should not be called");
             };
           }];

  XCTAssertEqual(self.mockDA.insertedDevices.count, 1);
  XCTAssertFalse([self.mockDA.insertedDevices allValues][0].wasMounted);
}

- (void)testNotifyUnmountFlushesCache {
  es_file_t file = MakeESFile("foo");
  es_process_t proc = MakeESProcess(&file);
  es_message_t esMsg = MakeESMessage(ES_EVENT_TYPE_NOTIFY_UNMOUNT, &proc);

  dispatch_semaphore_t semaMetrics = dispatch_semaphore_create(0);

  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();
  mockESApi->SetExpectationsESNewClient();
  mockESApi->SetExpectationsRetainReleaseMessage();

  auto mockAuthCache = std::make_shared<MockAuthResultCache>(nullptr, nil);
  EXPECT_CALL(*mockAuthCache, FlushCache);

  SNTEndpointSecurityDeviceManager *deviceManager = [[SNTEndpointSecurityDeviceManager alloc]
           initWithESAPI:mockESApi
                 metrics:nullptr
                  logger:nullptr
         authResultCache:mockAuthCache
           blockUSBMount:YES
          remountUSBMode:nil
      startupPreferences:SNTDeviceManagerStartupPreferencesNone];

  deviceManager.blockUSBMount = YES;

  [deviceManager handleMessage:Message(mockESApi, &esMsg)
            recordEventMetrics:^(EventDisposition d) {
              XCTAssertEqual(d, EventDisposition::kProcessed);
              dispatch_semaphore_signal(semaMetrics);
            }];

  XCTAssertSemaTrue(semaMetrics, 5, "Metrics not recorded within expected window");

  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
  XCTBubbleMockVerifyAndClearExpectations(mockAuthCache.get());
}

- (void)testPerformStartupTasks {
  SNTEndpointSecurityDeviceManager *deviceManager = [[SNTEndpointSecurityDeviceManager alloc] init];

  id partialDeviceManager = OCMPartialMock(deviceManager);
  OCMStub([partialDeviceManager shouldOperateOnDisk:nil]).ignoringNonObjectArgs().andReturn(YES);

  deviceManager.blockUSBMount = YES;
  deviceManager.remountArgs = @[ @"noexec", @"rdonly" ];

  [self.mockMounts insert:[[MockStatfs alloc] initFrom:@"d1" on:@"v1" flags:@(0x0)]];
  [self.mockMounts insert:[[MockStatfs alloc] initFrom:@"d2"
                                                    on:@"v2"
                                                 flags:@(MNT_RDONLY | MNT_NOEXEC | MNT_JOURNALED)]];

  // Disabling clang format due to local/remote version differences.
  // clang-format off
  // Create mock disks with desired args
  MockDADisk * (^CreateMockDisk)(NSString *, NSString *) =
    ^MockDADisk *(NSString *mountOn, NSString *mountFrom) {
      MockDADisk *mockDisk = [[MockDADisk alloc] init];
      mockDisk.diskDescription = @{
        @"DAVolumePath" : mountOn,      // f_mntonname,
        @"DADevicePath" : mountOn,      // f_mntonname,
        @"DAMediaBSDName" : mountFrom,  // f_mntfromname,
      };

      return mockDisk;
    };
  // clang-format on

  // Reset the Mock DA property, setup disks and remount args, then trigger the test
  void (^PerformStartupTest)(NSArray<MockDADisk *> *, NSArray<NSString *> *,
                             SNTDeviceManagerStartupPreferences) =
      ^void(NSArray<MockDADisk *> *disks, NSArray<NSString *> *remountArgs,
            SNTDeviceManagerStartupPreferences startupPref) {
        [self.mockDA reset];

        for (MockDADisk *d in disks) {
          [self.mockDA insert:d];
        }

        deviceManager.remountArgs = remountArgs;

        [deviceManager performStartupTasks:startupPref];
      };

  // Unmount with RemountUSBMode set
  {
    MockDADisk *disk1 = CreateMockDisk(@"v1", @"d1");
    MockDADisk *disk2 = CreateMockDisk(@"v2", @"d2");

    PerformStartupTest(@[ disk1, disk2 ], @[ @"noexec", @"rdonly" ],
                       SNTDeviceManagerStartupPreferencesUnmount);

    XCTAssertTrue(disk1.wasUnmounted);
    XCTAssertFalse(disk1.wasMounted);
    XCTAssertFalse(disk2.wasUnmounted);
    XCTAssertFalse(disk2.wasMounted);
  }

  // Unmount with RemountUSBMode nil
  {
    MockDADisk *disk1 = CreateMockDisk(@"v1", @"d1");
    MockDADisk *disk2 = CreateMockDisk(@"v2", @"d2");

    PerformStartupTest(@[ disk1, disk2 ], nil, SNTDeviceManagerStartupPreferencesUnmount);

    XCTAssertTrue(disk1.wasUnmounted);
    XCTAssertFalse(disk1.wasMounted);
    XCTAssertTrue(disk2.wasUnmounted);
    XCTAssertFalse(disk2.wasMounted);
  }

  // Remount with RemountUSBMode set
  {
    MockDADisk *disk1 = CreateMockDisk(@"v1", @"d1");
    MockDADisk *disk2 = CreateMockDisk(@"v2", @"d2");

    PerformStartupTest(@[ disk1, disk2 ], @[ @"noexec", @"rdonly" ],
                       SNTDeviceManagerStartupPreferencesRemount);

    XCTAssertTrue(disk1.wasUnmounted);
    XCTAssertTrue(disk1.wasMounted);
    XCTAssertFalse(disk2.wasUnmounted);
    XCTAssertFalse(disk2.wasMounted);
  }

  // Unmount with RemountUSBMode nil
  {
    MockDADisk *disk1 = CreateMockDisk(@"v1", @"d1");
    MockDADisk *disk2 = CreateMockDisk(@"v2", @"d2");

    PerformStartupTest(@[ disk1, disk2 ], nil, SNTDeviceManagerStartupPreferencesRemount);

    XCTAssertTrue(disk1.wasUnmounted);
    XCTAssertFalse(disk1.wasMounted);
    XCTAssertTrue(disk2.wasUnmounted);
    XCTAssertFalse(disk2.wasMounted);
  }
}

- (void)testUpdatedMountFlags {
  struct statfs sfs;

  strlcpy(sfs.f_fstypename, "foo", sizeof(sfs.f_fstypename));
  sfs.f_flags = MNT_JOURNALED | MNT_NOSUID | MNT_NODEV;

  SNTEndpointSecurityDeviceManager *deviceManager = [[SNTEndpointSecurityDeviceManager alloc] init];
  deviceManager.remountArgs = @[ @"noexec", @"rdonly" ];

  // For most filesystems, the flags are the union of what is in statfs and the remount args
  XCTAssertEqual([deviceManager updatedMountFlags:&sfs], sfs.f_flags | MNT_RDONLY | MNT_NOEXEC);

  // For APFS, flags are still unioned, but MNT_JOUNRNALED is cleared
  strlcpy(sfs.f_fstypename, "apfs", sizeof(sfs.f_fstypename));
  XCTAssertEqual([deviceManager updatedMountFlags:&sfs],
                 (sfs.f_flags | MNT_RDONLY | MNT_NOEXEC) & ~MNT_JOURNALED);
}

- (void)testEnable {
  // Ensure the client subscribes to expected event types
  std::set<es_event_type_t> expectedEventSubs{
      ES_EVENT_TYPE_AUTH_MOUNT,
      ES_EVENT_TYPE_AUTH_REMOUNT,
      ES_EVENT_TYPE_NOTIFY_UNMOUNT,
  };
  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();

  id deviceClient =
      [[SNTEndpointSecurityDeviceManager alloc] initWithESAPI:mockESApi
                                                      metrics:nullptr
                                                    processor:santa::Processor::kDeviceManager];

  EXPECT_CALL(*mockESApi, ClearCache(testing::_))
      .After(EXPECT_CALL(*mockESApi, Subscribe(testing::_, expectedEventSubs))
                 .WillOnce(testing::Return(true)))
      .WillOnce(testing::Return(true));

  [deviceClient enable];

  for (const auto &event : expectedEventSubs) {
    XCTAssertNoThrow(santa::EventTypeToString(event));
  }

  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
}

@end
