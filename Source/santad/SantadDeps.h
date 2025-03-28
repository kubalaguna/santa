/// Copyright 2022 Google Inc. All rights reserved.
/// Copyright 2024 North Pole Security, Inc.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///     http://www.apache.org/licenses/LICENSE-2.0
///
/// Unless required by applicable law or agreed to in writing, software
/// distributed under the License is distributed on an "AS IS" BASIS,
/// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
/// See the License for the specific language governing permissions and
/// limitations under the License.

#ifndef SANTA__SANTAD__SANTAD_DEPS_H
#define SANTA__SANTAD__SANTAD_DEPS_H

#import <Foundation/Foundation.h>

#include <memory>

#import "Source/common/MOLXPCConnection.h"
#include "Source/common/PrefixTree.h"
#import "Source/common/SNTConfigurator.h"
#import "Source/common/SNTMetricSet.h"
#include "Source/common/Unit.h"
#include "Source/santad/DataLayer/WatchItems.h"
#include "Source/santad/EventProviders/AuthResultCache.h"
#include "Source/santad/EventProviders/EndpointSecurity/EndpointSecurityAPI.h"
#include "Source/santad/EventProviders/EndpointSecurity/Enricher.h"
#include "Source/santad/Logs/EndpointSecurity/Logger.h"
#include "Source/santad/Metrics.h"
#include "Source/santad/ProcessControl.h"
#include "Source/santad/ProcessTree/process_tree.h"
#import "Source/santad/SNTCompilerController.h"
#import "Source/santad/SNTExecutionController.h"
#import "Source/santad/SNTNotificationQueue.h"
#import "Source/santad/SNTSyncdQueue.h"
#include "Source/santad/TTYWriter.h"

namespace santa {

class SantadDeps {
 public:
  static std::unique_ptr<SantadDeps> Create(
      SNTConfigurator *configurator, SNTMetricSet *metric_set,
      santa::ProcessControlBlock processControlBlock);

  SantadDeps(
      std::shared_ptr<santa::EndpointSecurityAPI> esapi,
      std::unique_ptr<santa::Logger> logger,
      std::shared_ptr<santa::Metrics> metrics,
      std::shared_ptr<santa::WatchItems> watch_items,
      std::shared_ptr<santa::AuthResultCache> auth_result_cache,
      MOLXPCConnection *control_connection,
      SNTCompilerController *compiler_controller,
      SNTNotificationQueue *notifier_queue, SNTSyncdQueue *syncd_queue,
      SNTExecutionController *exec_controller,
      std::shared_ptr<santa::PrefixTree<santa::Unit>> prefix_tree,
      std::shared_ptr<santa::TTYWriter> tty_writer,
      std::shared_ptr<santa::santad::process_tree::ProcessTree> process_tree);

  std::shared_ptr<santa::AuthResultCache> AuthResultCache();
  std::shared_ptr<santa::Enricher> Enricher();
  std::shared_ptr<santa::EndpointSecurityAPI> ESAPI();
  std::shared_ptr<santa::Logger> Logger();
  std::shared_ptr<santa::Metrics> Metrics();
  std::shared_ptr<santa::WatchItems> WatchItems();
  MOLXPCConnection *ControlConnection();
  SNTCompilerController *CompilerController();
  SNTNotificationQueue *NotifierQueue();
  SNTSyncdQueue *SyncdQueue();
  SNTExecutionController *ExecController();
  std::shared_ptr<santa::PrefixTree<santa::Unit>> PrefixTree();
  std::shared_ptr<santa::TTYWriter> TTYWriter();
  std::shared_ptr<santa::santad::process_tree::ProcessTree> ProcessTree();

 private:
  std::shared_ptr<santa::EndpointSecurityAPI> esapi_;
  std::shared_ptr<santa::Logger> logger_;
  std::shared_ptr<santa::Metrics> metrics_;
  std::shared_ptr<santa::WatchItems> watch_items_;
  std::shared_ptr<santa::Enricher> enricher_;
  std::shared_ptr<santa::AuthResultCache> auth_result_cache_;

  MOLXPCConnection *control_connection_;
  SNTCompilerController *compiler_controller_;
  SNTNotificationQueue *notifier_queue_;
  SNTSyncdQueue *syncd_queue_;
  SNTExecutionController *exec_controller_;
  std::shared_ptr<santa::PrefixTree<santa::Unit>> prefix_tree_;
  std::shared_ptr<santa::TTYWriter> tty_writer_;
  std::shared_ptr<santa::santad::process_tree::ProcessTree> process_tree_;
};

}  // namespace santa

#endif
