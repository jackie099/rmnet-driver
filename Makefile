CXX := clang++

CORE_FLAGS := -std=c++17 -Wall -Wextra -Werror -fno-exceptions -fno-rtti
TEST_FLAGS := -std=c++17 -Wall -Wextra -Werror
HARNESS_FLAGS := -std=c++17 -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

CORE_SRCS := $(wildcard core/src/*.cpp)
TEST_SRCS := $(wildcard tests/test_*.cpp)
HARNESS_SRCS := $(wildcard harness/*.mm)

CORE_OBJS := $(patsubst core/src/%.cpp,build/obj/core/%.o,$(CORE_SRCS))
TEST_OBJS := $(patsubst tests/%.cpp,build/obj/tests/%.o,$(TEST_SRCS))
HARNESS_OBJS := $(patsubst harness/%.mm,build/obj/harness/%.o,$(HARNESS_SRCS))

.PHONY: test driver-test check-driverkit app-test script-test harness driver clean

test: build/tests
	./build/tests $(FILTER)

build/tests: $(CORE_OBJS) $(TEST_OBJS)
	$(CXX) -o $@ $^

build/obj/core/%.o: core/src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -MMD -MP -c $< -o $@

build/obj/tests/%.o: tests/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(TEST_FLAGS) -Icore/include -Itests -MMD -MP -c $< -o $@

# CoreHost (driver/core_host.cpp) on the host, behind fakes of UsbPort and RxSink, built with Core's
# flags, tests and runner included.
# Every tests/driver/test_*.cpp is built. `make driver-test FILTER=kept` runs only tests whose name
# contains it.
DRIVER_TEST_SRCS := $(wildcard tests/driver/test_*.cpp)
DRIVER_TEST_OBJS := build/obj/driver/core_host.o \
	$(patsubst tests/driver/%.cpp,build/obj/driver-tests/%.o,$(DRIVER_TEST_SRCS)) \
	build/obj/driver-tests/test_main.o

driver-test: build/driver-tests
	./build/driver-tests $(FILTER)

build/driver-tests: $(CORE_OBJS) $(DRIVER_TEST_OBJS)
	$(CXX) -o $@ $^

build/obj/driver/core_host.o: driver/core_host.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -MMD -MP -c $< -o $@

build/obj/driver-tests/%.o: tests/driver/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -Idriver -Itests -MMD -MP -c $< -o $@

build/obj/driver-tests/test_main.o: tests/test_main.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Itests -MMD -MP -c $< -o $@

harness: build/rmnet-harness

build/rmnet-harness: $(CORE_OBJS) $(HARNESS_OBJS)
	$(CXX) -o $@ $^ -framework IOUSBHost -framework IOKit -framework Foundation

build/obj/harness/%.o: harness/%.mm
	@mkdir -p $(dir $@)
	$(CXX) $(HARNESS_FLAGS) -Icore/include -MMD -MP -c $< -o $@

check-driverkit:
	./scripts/check-driverkit-compile.sh
	./scripts/check-personalities.sh

# The app's status model, SMS model, AT answer logic, the Messages tab's controller, the gps verb's
# NMEA logic, its port reader and its GNSS switching (against a fake switch and a scripted port), the
# network model, the settings model, the modem service (against a scripted port), the modem verbs (against
# a fake service), the modem tabs' controller, the quit gate (with both controllers), the menu bar item's
# model (against fake sources), the window's own visibility for the modem tabs (against posted
# notifications), the signal's bars and quality zones, the throughput sampler (against fake counters and a
# fake clock), the window's screens with the polls they run, what the Network screen's cards show and the
# Overview's cards, tested without Xcode or hardware (neither the AT port nor the NMEA port is opened: the reader
# reads a pseudo-terminal the test makes, and no window is made).
app-test: build/app-tests build/sms-tests build/at-tests build/smsui-tests build/nmea-tests build/gpsread-tests \
		build/modemnet-tests build/modemset-tests build/modemsvc-tests build/modemcli-tests build/modemui-tests \
		build/quit-tests build/menubar-tests build/window-tests build/signal-tests build/throughput-tests \
		build/shell-tests build/networkview-tests build/overview-tests build/imeihistory-tests build/simslot-tests \
		build/messagealerts-tests build/smsservice-tests build/conversations-tests build/pulse-tests \
		build/resultline-tests build/smsledger-tests build/replyeditor-tests
	./build/app-tests
	./build/sms-tests
	./build/at-tests
	./build/smsui-tests
	./build/nmea-tests
	./build/gpsread-tests
	./build/modemnet-tests
	./build/modemset-tests
	./build/modemsvc-tests
	./build/modemcli-tests
	./build/modemui-tests
	./build/quit-tests
	./build/menubar-tests
	./build/window-tests
	./build/signal-tests
	./build/throughput-tests
	./build/shell-tests
	./build/networkview-tests
	./build/overview-tests
	./build/imeihistory-tests
	./build/simslot-tests
	./build/messagealerts-tests
	./build/smsservice-tests
	./build/conversations-tests
	./build/pulse-tests
	./build/resultline-tests
	./build/smsledger-tests
	./build/replyeditor-tests

build/app-tests: app/StatusModel.swift tests/app/StatusModelTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/sms-tests: app/SmsModel.swift tests/app/SmsModelTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/at-tests: app/AtPort.swift tests/app/AtPortTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/smsui-tests: app/SmsModel.swift app/ModemNetwork.swift app/ModemSettings.swift app/MessageAlerts.swift \
		app/SmsConversations.swift app/ResultLine.swift app/SmsController.swift tests/app/SmsControllerTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/nmea-tests: app/Nmea.swift tests/app/NmeaTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The gps verb switches GNSS over the AT port: AtPort.swift, ModemService.swift (AtCommanding), SmsService.swift
# (describe) and what they need. The tests drive a fake switch and a scripted port; no port is opened.
build/gpsread-tests: app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/SmsSendLedger.swift app/ModemNetwork.swift \
		app/ModemSettings.swift app/ModemService.swift app/Nmea.swift app/GpsCommand.swift tests/app/GpsReadTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemnet-tests: app/ModemNetwork.swift tests/app/ModemNetworkTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemset-tests: app/ModemNetwork.swift app/ModemSettings.swift tests/app/ModemSettingsTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# SmsService.swift brings describe(_: AtError).
build/modemsvc-tests: app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/SmsSendLedger.swift app/ModemNetwork.swift \
		app/ModemSettings.swift app/ModemService.swift tests/app/ModemServiceTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemcli-tests: app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift app/ModemCli.swift tests/app/ModemCliTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemui-tests: app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift app/ResultLine.swift app/ModemController.swift tests/app/ModemControllerTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/quit-tests: app/SmsModel.swift app/MessageAlerts.swift app/SmsConversations.swift app/ResultLine.swift app/SmsController.swift app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift \
		app/ModemController.swift app/QuitGate.swift app/SimSlotWatch.swift tests/app/QuitGateTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The menu bar item's model: the status model for the headline, the AT port's and the modem's files for the
# failures' wording (the real ModemService, behind a port that never opens), the signal's bars for the signal bars
# style (its setting in a user defaults suite of the test's own). No port is opened.
build/menubar-tests: app/StatusModel.swift app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/SmsSendLedger.swift \
		app/ModemNetwork.swift app/ModemSettings.swift app/ModemService.swift app/SignalQuality.swift app/MenuBarStatus.swift \
		tests/app/MenuBarStatusTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/window-tests: app/WindowVisibility.swift tests/app/WindowVisibilityTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/signal-tests: app/ModemNetwork.swift app/SignalQuality.swift tests/app/SignalQualityTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/throughput-tests: app/ThroughputSampler.swift tests/app/ThroughputSamplerTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The screens map to the modem's reads (ModemTab), and every headline of StatusModel.swift has a pill.
build/shell-tests: app/StatusModel.swift app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift app/ResultLine.swift app/ModemController.swift \
		app/ShellModel.swift tests/app/ShellModelTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The Network screen's cards (NetworkView.swift's NetworkCards); its views, and the files they use, are compiled
# but never drawn.
build/networkview-tests: app/StatusModel.swift app/Registry.swift app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift \
		app/ResultLine.swift app/ModemController.swift app/ShellModel.swift app/SignalQuality.swift app/ThroughputSampler.swift \
		app/ModemViewParts.swift app/DesignKit.swift app/Charts.swift app/NetworkView.swift \
		tests/app/NetworkViewTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# What the Overview's cards say: the signal history and the SIM read (ModemController, ModemSettings), the
# driver's status and advice (StatusModel), the pill the driver card agrees with (ShellModel), the quality zones.
build/overview-tests: app/StatusModel.swift app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift app/ResultLine.swift app/ModemController.swift \
		app/ShellModel.swift app/SignalQuality.swift app/OverviewModel.swift tests/app/OverviewModelTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The IMEI history: its lines, the file (in a temporary folder), the entries made from changes, what `imei history`
# prints and the SIM & Data screen's rows.
build/imeihistory-tests: app/ModemNetwork.swift app/ModemSettings.swift app/ImeiHistory.swift tests/app/ImeiHistoryTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# Switching SIM slots by itself (when, and never back and forth) and the app's settings.
build/simslot-tests: app/ModemNetwork.swift app/ModemSettings.swift app/SimSlotWatch.swift app/AppSettings.swift \
		tests/app/SimSlotWatchTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# New messages in the background: the count, the baseline, what is new and what a notification says; the Messages
# controller's part, against a fake service (the background turn itself: build/pulse-tests).
build/messagealerts-tests: app/SmsModel.swift app/ModemNetwork.swift app/ModemSettings.swift app/MessageAlerts.swift \
		app/ModemPulse.swift app/SmsConversations.swift app/ResultLine.swift app/SmsController.swift tests/app/MessageAlertsTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# Sending from the modem's store (AT+CMGW, AT+CMSS), Retry and the direct send, against a scripted port.
build/smsservice-tests: app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/SmsSendLedger.swift tests/app/SmsServiceTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The Messages screen's conversations: grouping by number, the order within one, previews and words.
build/conversations-tests: app/SmsModel.swift app/SmsConversations.swift tests/app/SmsConversationsTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The background turn as the app wires it: the real short reads behind a scripted port, the menu bar's signal bars and
# two recording riders; a busy port and a timeout part way through a turn.
build/pulse-tests: app/StatusModel.swift app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/SmsSendLedger.swift \
		app/ModemNetwork.swift app/ModemSettings.swift app/ModemService.swift app/SignalQuality.swift app/MenuBarStatus.swift \
		app/ModemPulse.swift tests/app/ModemPulseTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# A result line's banner: a success goes after 8 s (not under the pointer), the rest stay; on a fake clock.
build/resultline-tests: app/ResultLine.swift tests/app/ResultLineTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The record of sent messages: its lines, the latest state of each part, the file kept only as it should be.
build/smsledger-tests: app/SmsSendLedger.swift tests/app/SmsSendLedgerTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The reply field off screen (AppKit): text an input method still composes when the field goes is committed to its
# own conversation, never to the next one's.
build/replyeditor-tests: app/PlainTextEditor.swift tests/app/PlainTextEditorTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The scripts' decisions that need neither the network nor an install: the install script's
# installed-app ID, kept-app and running-driver checks (scripts/install-checks.sh), soak.sh's status
# classes (--classify), the driver's personalities against the model list
# (scripts/check-personalities.sh), and the build's team and bundle IDs and its IPv6-only preferred
# setting from config.local or the environment (scripts/config.sh, gen.rb's options).
script-test:
	sh tests/scripts/test-install-checks.sh
	sh tests/scripts/test-soak-classify.sh
	sh tests/scripts/test-personalities.sh
	sh tests/scripts/test-config.sh

# Unsigned build of the driver and the host app that embeds it. gen.rb writes RMNet.xcodeproj, with
# the bundle ID in RMNET_BUNDLE_ID when it is set (environment or make's command line; config.local
# is not read here), else the default, and with the driver's RMNetIPv6OnlyPreferred 1 when
# RMNET_IPV6_ONLY_PREFERRED is 1, else 0 as in driver/Info.plist.
XCODEBUILD := xcodebuild -project RMNet.xcodeproj -configuration Debug -parallelizeTargets \
	SYMROOT="$(CURDIR)/build/xcode" OBJROOT="$(CURDIR)/build/xcode/obj" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# RMNET_IPV6_ONLY_PREFERRED is compared here as it is, before it reaches any command: $(value ...)
# leaves a $(...) in it unexpanded, and ifeq keeps its blanks. Empty, 0 and 1 give the constant gen.rb
# argument below; any other value stops the driver target before any of its commands runs (the
# message, through $(error), quotes it without expanding it), and leaves every other target alone.
# Only that constant reaches the shell, never the value itself, so the variable must never be
# expanded as itself anywhere in this file, only through $(value ...).
# (On make's command line, VAR= 1 is make's own assignment syntax and gives 1, as in a makefile; a
# blank after the value is kept and refused.)
ifeq ($(value RMNET_IPV6_ONLY_PREFERRED),)
  GEN_IPV6_ONLY_PREFERRED :=
else ifeq ($(value RMNET_IPV6_ONLY_PREFERRED),0)
  GEN_IPV6_ONLY_PREFERRED := --ipv6-only-preferred 0
else ifeq ($(value RMNET_IPV6_ONLY_PREFERRED),1)
  GEN_IPV6_ONLY_PREFERRED := --ipv6-only-preferred 1
else
  GEN_IPV6_ONLY_PREFERRED_REFUSED := RMNET_IPV6_ONLY_PREFERRED '$(value RMNET_IPV6_ONLY_PREFERRED)' is not empty, 0 or 1
endif

driver:
	$(if $(GEN_IPV6_ONLY_PREFERRED_REFUSED),$(error $(GEN_IPV6_ONLY_PREFERRED_REFUSED); nothing was built))
	/usr/bin/ruby gen.rb $(if $(RMNET_BUNDLE_ID),--bundle-id $(RMNET_BUNDLE_ID)) $(GEN_IPV6_ONLY_PREFERRED)
	$(XCODEBUILD) -target RMNetDriver build
	$(XCODEBUILD) -target RMNet build
	@echo "driver build ok"

# build/installed keeps the apps that can deactivate an installed driver (scripts/install-driver.sh).
clean:
	[ ! -d build ] || find build -mindepth 1 -maxdepth 1 ! -name installed -exec rm -rf {} +

-include $(CORE_OBJS:.o=.d) $(TEST_OBJS:.o=.d) $(HARNESS_OBJS:.o=.d) $(DRIVER_TEST_OBJS:.o=.d)
