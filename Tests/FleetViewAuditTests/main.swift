import Foundation

// Test registry. Without XCTest there is no runtime discovery, so suites are listed explicitly —
// which has the side benefit of reading as a table of contents for what the audit engine promises.
//
//     swift run FleetViewAuditTests

func suite<T: XCTestCase>(_ name: String,
                          _ type: T.Type,
                          _ cases: [(String, (T) -> () throws -> Void)]) -> (String, [Test]) {
    (name, cases.map { label, method in
        Test(label) {
            let instance = T()
            instance.setUp()
            defer { instance.tearDown() }
            try method(instance)()
        }
    })
}

let suites: [(String, [Test])] = [
    suite("AuditValue — the wire format", AuditValueTests.self, [
        ("object keys are sorted", AuditValueTests.testObjectKeysAreSorted),
        ("newlines and tabs are escaped", AuditValueTests.testNewlinesAndTabsAreEscaped),
        ("other control characters are escaped", AuditValueTests.testOtherControlCharactersBecomeUnicodeEscapes),
        ("quotes and backslashes are escaped", AuditValueTests.testQuotesAndBackslashesAreEscaped),
        ("integers and booleans do not collapse", AuditValueTests.testIntegersAndBooleansDoNotCollapse),
        ("whole doubles print without a decimal point", AuditValueTests.testWholeDoublesPrintWithoutDecimalPoint),
        ("non-finite doubles become null", AuditValueTests.testNonFiniteDoublesBecomeNull),
        ("compact drops nil and null", AuditValueTests.testCompactDropsNilAndNull),
        ("nested structures encode", AuditValueTests.testNestedStructuresEncode),
        ("encoded output parses as JSON", AuditValueTests.testEncodedOutputParsesAsJSON),
        ("CJK survives a round trip", AuditValueTests.testCJKSurvivesRoundTrip),
    ]),

    suite("Identifiers — ULID and UUIDv7", IdentifiersTests.self, [
        ("ULID is 26 characters", IdentifiersTests.testULIDIsCanonicalLength),
        ("ULID uses the Crockford alphabet", IdentifiersTests.testULIDUsesCrockfordAlphabetOnly),
        ("ULIDs sort by time", IdentifiersTests.testULIDsSortByTime),
        ("ULIDs in the same millisecond stay ordered", IdentifiersTests.testULIDsInSameMillisecondStayOrdered),
        ("UUIDv7 has UUID shape", IdentifiersTests.testUUIDv7HasUUIDShape),
        ("UUIDv7 sets version and variant nibbles", IdentifiersTests.testUUIDv7SetsVersionAndVariantNibbles),
        ("UUIDv7 sorts chronologically as strings", IdentifiersTests.testUUIDv7SortsChronologicallyAsPlainStrings),
        ("UUIDv7 encodes the timestamp", IdentifiersTests.testUUIDv7EncodesTheTimestampInTheFirst48Bits),
        ("UUIDv7 same-millisecond ids are unique", IdentifiersTests.testUUIDv7SameMillisecondIdsAreUniqueAndOrdered),
    ]),

    suite("SnapshotDiff — change detection", SnapshotDiffTests.self, [
        ("addition is detected", SnapshotDiffTests.testAdditionIsDetected),
        ("removal is detected", SnapshotDiffTests.testRemovalIsDetected),
        ("modification reports only changed fields", SnapshotDiffTests.testModificationReportsOnlyChangedFields),
        ("identical snapshots produce nothing", SnapshotDiffTests.testIdenticalSnapshotsProduceNothing),
        ("appearing and disappearing fields are changes", SnapshotDiffTests.testAppearingAndDisappearingFieldsAreChanges),
        ("different kinds with the same id do not collide", SnapshotDiffTests.testDifferentKindsWithTheSameIdDoNotCollide),
        ("ordering is deterministic", SnapshotDiffTests.testOrderingIsDeterministic),
    ]),

    suite("StateAuditor — changes become events", StateAuditorTests.self, [
        ("creation captures identity fields", StateAuditorTests.testCreationCapturesIdentityFields),
        ("removal is logged", StateAuditorTests.testRemovalIsLogged),
        ("rename becomes its own event", StateAuditorTests.testRenameBecomesItsOwnEvent),
        ("status change becomes its own event", StateAuditorTests.testStatusChangeBecomesItsOwnEvent),
        ("cluster membership change becomes its own event", StateAuditorTests.testClusterMembershipChangeBecomesItsOwnEvent),
        ("transcript and session collapse into one event", StateAuditorTests.testTranscriptAndSessionCollapseIntoOneEvent),
        ("an unclassified field is still logged", StateAuditorTests.testUnclassifiedFieldStillProducesAnEvent),
        ("an unknown entity kind falls back to generic", StateAuditorTests.testUnknownEntityKindFallsBackToAGenericEvent),
        ("ignored fields are suppressed", StateAuditorTests.testIgnoredFieldsAreSuppressed),
        ("an ignored field does not mask a real change", StateAuditorTests.testIgnoredFieldDoesNotMaskARealChange),
        ("an operation that changes nothing is still logged", StateAuditorTests.testOperationThatChangesNothingIsStillLogged),
        ("a failed operation is logged as an alert", StateAuditorTests.testFailedOperationIsLoggedAsAnAlert),
        ("intent rides along on derived events", StateAuditorTests.testIntentRidesAlongOnDerivedEvents),
        ("intent does not overwrite derived fields", StateAuditorTests.testIntentDoesNotOverwriteDerivedFields),
        ("selecting a terminal is logged", StateAuditorTests.testSelectingATerminalIsLogged),
        ("actor is attached to every event", StateAuditorTests.testActorIsAttachedToEveryEvent),
        ("several entities each produce events", StateAuditorTests.testSeveralEntitiesEachProduceTheirOwnEvents),
        ("messages are human readable", StateAuditorTests.testMessagesAreHumanReadable),
    ]),

    suite("AuditContext — who did it", AuditContextTests.self, [
        ("fallback applies outside any scope", AuditContextTests.testFallbackAppliesOutsideAnyScope),
        ("scope overrides the fallback", AuditContextTests.testScopeOverridesTheFallback),
        ("scope is restored afterwards", AuditContextTests.testScopeIsRestoredAfterwards),
        ("scopes nest", AuditContextTests.testScopesNest),
        ("scope is restored when the body throws", AuditContextTests.testScopeIsRestoredWhenTheBodyThrows),
        ("trace is inherited by inner scopes", AuditContextTests.testTraceIsInheritedByInnerScopes),
        ("scope returns the body's value", AuditContextTests.testScopeReturnsTheBodysValue),
        ("context is per thread", AuditContextTests.testContextIsPerThread),
        ("auditor stamps the ambient actor", AuditContextTests.testAuditorStampsTheAmbientActorOntoEmittedEvents),
        ("an explicit actor wins", AuditContextTests.testExplicitActorOnAnEventWins),
    ]),

    suite("Envelope and sinks", EnvelopeAndSinkTests.self, [
        ("a line is single-line valid JSON", EnvelopeAndSinkTests.testLineIsSingleLineValidJSON),
        ("envelope carries ECS and resource fields", EnvelopeAndSinkTests.testEnvelopeCarriesTheECSAndResourceFields),
        ("target keeps both id and name", EnvelopeAndSinkTests.testTargetKeepsBothIdAndName),
        ("network actor fields are promoted to ECS top level", EnvelopeAndSinkTests.testNetworkActorFieldsArePromotedToECSTopLevel),
        ("desktop events carry no network fields", EnvelopeAndSinkTests.testDesktopEventsCarryNoNetworkFields),
        ("sequence increments monotonically", EnvelopeAndSinkTests.testSequenceIncrementsMonotonically),
        ("timestamp has milliseconds and an offset", EnvelopeAndSinkTests.testTimestampCarriesAnOffsetAndMilliseconds),
        ("empty sections are omitted, not null", EnvelopeAndSinkTests.testEmptySectionsAreOmittedRatherThanNull),
        ("an oversized event is truncated below the atomic-write limit", EnvelopeAndSinkTests.testOversizedEventIsTruncatedBelowTheAtomicWriteLimit),
        ("normal events are not truncated", EnvelopeAndSinkTests.testNormalEventsAreNotTruncated),
        ("file sink writes a header then events", EnvelopeAndSinkTests.testFileSinkWritesHeaderThenEvents),
        ("file sink appends rather than overwrites", EnvelopeAndSinkTests.testFileSinkAppendsRatherThanOverwrites),
        ("file sink creates private files", EnvelopeAndSinkTests.testFileSinkCreatesPrivateFiles),
        ("a disabled auditor writes nothing", EnvelopeAndSinkTests.testDisabledAuditorWritesNothing),
        ("the failure helper produces an alert", EnvelopeAndSinkTests.testFailureHelperProducesAnAlert),
    ]),

    suite("Web requests — attribution and noise control", WebRequestTests.self, [
        ("loopback is recognised", WebRequestTests.testLoopbackIsRecognised),
        ("private ranges are LAN", WebRequestTests.testPrivateRangesAreLAN),
        ("the CGNAT range is Tailscale", WebRequestTests.testCGNATRangeIsTailscale),
        ("addresses just outside CGNAT are not", WebRequestTests.testAddressesJustOutsideCGNATAreNotTailscale),
        ("public addresses are recognised", WebRequestTests.testPublicAddressesAreRecognised),
        ("IPv4-mapped IPv6 is unwrapped", WebRequestTests.testIPv4MappedIPv6IsUnwrapped),
        ("request line and query are parsed", WebRequestTests.testRequestLineAndQueryAreParsed),
        ("header names are case-insensitive", WebRequestTests.testHeaderNamesAreCaseInsensitive),
        ("cookies are parsed", WebRequestTests.testCookiesAreParsed),
        ("a missing cookie header is empty", WebRequestTests.testMissingCookieHeaderIsEmpty),
        ("forwarded-for keeps only the first hop", WebRequestTests.testForwardedForKeepsOnlyTheFirstHop),
        ("FleetView tools identify themselves", WebRequestTests.testFleetViewToolsIdentifyThemselves),
        ("malformed requests are rejected", WebRequestTests.testMalformedRequestsAreRejected),
        ("polled endpoints are not audited per request", WebRequestTests.testPolledEndpointsAreNotAuditedPerRequest),
        ("mutating endpoints are audited", WebRequestTests.testMutatingEndpointsAreAudited),
        ("documents are not audited per request", WebRequestTests.testDocumentsAreNotAuditedPerRequest),
        ("the first request starts a session", WebRequestTests.testFirstRequestStartsASession),
        ("a known session is reused", WebRequestTests.testKnownSessionIsReused),
        ("a stale cookie starts a fresh session", WebRequestTests.testAStaleCookieStartsAFreshSession),
        ("a cookieless poller reuses its session", WebRequestTests.testACookielessPollerReusesItsSession),
        ("different cookieless clients stay separate", WebRequestTests.testDifferentCookielessClientsStaySeparate),
        ("a cookie always wins over the fallback", WebRequestTests.testACookieAlwaysWinsOverTheFallback),
        ("a cookieless client does not adopt an expired session", WebRequestTests.testACookielessClientDoesNotAdoptAnExpiredSession),
        ("favicon is not audited", WebRequestTests.testFaviconIsNotAudited),
        ("rollups collect poll counts then reset", WebRequestTests.testRollupsCollectPollCountsAndThenReset),
        ("idle sessions expire once", WebRequestTests.testIdleSessionsExpireAndAreReturnedOnce),
        ("selection changes are tracked", WebRequestTests.testSelectionChangeIsTracked),
        ("a session becomes a web actor", WebRequestTests.testSessionBecomesAWebActorWithNetworkFields),
        ("device labels are readable", WebRequestTests.testDeviceLabelsAreReadable),
    ]),

    suite("Panel versioning", PanelVersioningTests.self, [
        ("identical content is not archived twice", PanelVersioningTests.testIdenticalContentIsNotArchivedTwice),
        ("changed content is captured", PanelVersioningTests.testChangedContentIsCaptured),
        ("the first ever panel is captured", PanelVersioningTests.testFirstEverPanelIsCaptured),
        ("empty content is rejected", PanelVersioningTests.testEmptyContentIsRejected),
        ("truncation is detected but not fatal", PanelVersioningTests.testTruncationIsDetectedButNotFatal),
        ("the digest is stable", PanelVersioningTests.testDigestIsStable),
        ("title comes from the document title", PanelVersioningTests.testTitleComesFromTheDocumentTitle),
        ("title falls back to the first heading", PanelVersioningTests.testTitleFallsBackToTheFirstHeading),
        ("title strips nested markup", PanelVersioningTests.testTitleStripsNestedMarkup),
        ("a title-less panel is allowed", PanelVersioningTests.testTitlelessPanelIsAllowed),
        ("the Write tool is matched by path", PanelVersioningTests.testWriteToolIsMatchedByPath),
        ("a bash heredoc is matched by command", PanelVersioningTests.testBashHeredocIsMatchedByCommand),
        ("unrelated tool calls do not match", PanelVersioningTests.testUnrelatedToolCallsDoNotMatch),
        ("panel.json writes are not panel writes", PanelVersioningTests.testPanelDataWritesDoNotCountAsPanelWrites),
        ("a hook match wins outright", PanelVersioningTests.testAHookMatchWinsOutright),
        ("the most recent hook match wins", PanelVersioningTests.testTheMostRecentHookMatchWins),
        ("stale hook matches are ignored", PanelVersioningTests.testStaleHookMatchesAreIgnored),
        ("a single active terminal is inferred", PanelVersioningTests.testASingleActiveTerminalIsInferred),
        ("several active terminals stay ambiguous", PanelVersioningTests.testSeveralActiveTerminalsStayAmbiguous),
        ("nothing known is recorded as unknown", PanelVersioningTests.testNothingKnownIsRecordedAsUnknown),
        ("the version filename is the uuid", PanelVersioningTests.testVersionFilenameIsTheUUID),
        ("the index line carries provenance", PanelVersioningTests.testIndexLineIsValidJSONWithProvenance),
        ("audit data carries the same provenance", PanelVersioningTests.testAuditDataCarriesTheSameProvenance),
        ("rollback links back to what it restored", PanelVersioningTests.testRollbackKeepsALinkToWhatItRestored),
        ("ambiguous attribution lists candidates", PanelVersioningTests.testAmbiguousAttributionListsCandidates),
    ]),

    suite("Model projection — Codable to audited fields", ModelProjectionTests.self, [
        ("every field is projected", ModelProjectionTests.testEveryFieldIsProjected),
        ("booleans do not become integers", ModelProjectionTests.testBooleansDoNotBecomeIntegers),
        ("UUIDs become strings", ModelProjectionTests.testUUIDsBecomeStrings),
        ("nil optionals are absent, not null", ModelProjectionTests.testNilOptionalsAreAbsentRatherThanNull),
        ("dropped keys are excluded", ModelProjectionTests.testDroppedKeysAreExcluded),
        ("a newly added field needs no registration", ModelProjectionTests.testANewlyAddedFieldNeedsNoRegistration),
        ("nested values survive", ModelProjectionTests.testNestedValuesSurvive),
        ("non-object values project to nothing", ModelProjectionTests.testNonObjectValuesProjectToNothing),
        ("the JSON bridge handles every scalar", ModelProjectionTests.testJSONBridgeHandlesEveryScalar),
    ]),

    suite("End to end — a whole session on disk", IntegrationTests.self, [
        ("the whole narrative is recorded", IntegrationTests.testTheWholeNarrativeIsRecorded),
        ("every line is one record under the atomic limit", IntegrationTests.testEveryLineIsOneRecordUnderTheAtomicLimit),
        ("each event is attributed to whoever caused it", IntegrationTests.testEachEventIsAttributedToWhoeverCausedIt),
        ("the log never contains a secret", IntegrationTests.testTheLogNeverContainsASecret),
        ("conversation content is referenced, never copied", IntegrationTests.testConversationContentIsReferencedNeverCopied),
        ("a panel version says which conversation produced it", IntegrationTests.testPanelVersionSaysWhichConversationProducedIt),
        ("sequence numbers have no gaps", IntegrationTests.testSequenceNumbersHaveNoGaps),
        ("event ids sort in written order", IntegrationTests.testEventIdsSortInWrittenOrder),
        ("a reader can follow one request end to end", IntegrationTests.testAReaderCanFollowOneRequestEndToEnd),
    ]),

    suite("Redaction — secrets never reach the log", RedactionTests.self, [
        ("environment assignments are masked", RedactionTests.testEnvironmentAssignmentIsMasked),
        ("password and token flags are masked", RedactionTests.testPasswordAndTokenFlagsAreMasked),
        ("authorization headers are masked", RedactionTests.testAuthorizationHeadersAreMasked),
        ("basic-auth credentials are masked", RedactionTests.testBasicAuthCredentialsAreMasked),
        ("well-known token shapes are masked anywhere", RedactionTests.testWellKnownTokenShapesAreMaskedAnywhere),
        ("ordinary commands are untouched", RedactionTests.testOrdinaryCommandsAreUntouched),
        ("redaction is reported", RedactionTests.testRedactionIsReported),
        ("redaction is idempotent", RedactionTests.testRedactionIsIdempotent),
    ]),
]

exit(TestRunner.run(suites))
