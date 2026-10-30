import Foundation
import Testing
@testable import SplitvoxNotion

// Unit tests: raw, isolated JSON documents; no user preferences or API calls.
@Suite("External hook migration")
struct HookMigrationTests {
    let old = "/Applications/My App'Test.app/Contents/MacOS/Splitvox"
    let new = "/tmp/my bin'&/splitvox-notion"
    func config(_ enabled: Bool = true) -> LegacyNotionPreferences {
        .init(enabled: enabled, cliPath: "/tmp/ntn'$(no-op)", parentPageID: "parent'&", windowMinutes: 37)
    }
    func document(command: String, enabled: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject:["version":1,"metadata":"retain-root","hooks":[[
            "id":"11111111-1111-4111-8111-111111111111","name":"Renamed hook","enabled":enabled,
            "event":"recording_stopped","command":command,"timeoutSeconds":600,"extra":"retain-entry"
        ]]])
    }
    @Test("Only executable changes; IDs, enablement, arguments and unknown fields survive", arguments:[true,false])
    func rewrite(enabled: Bool) throws {
        let legacy=config(enabled)
        let input=try document(command:HookMigration.legacyCommand(legacy,executable:old),enabled:enabled)
        let result=try HookMigration.prepare(document:input,legacy:JSONEncoder().encode(legacy),startCommand:"",stopCommand:"",oldExecutable:old,newExecutable:new)
        let json=try JSONSerialization.jsonObject(with:result.document) as! [String:Any]
        let hooks=json["hooks"] as! [[String:Any]]
        #expect(result.changedHooks==1)
        #expect(json["metadata"] as? String == "retain-root")
        #expect(hooks[0]["extra"] as? String == "retain-entry")
        #expect(hooks[0]["id"] as? String == "11111111-1111-4111-8111-111111111111")
        #expect(hooks[0]["enabled"] as? Bool == enabled)
        #expect(hooks[0]["command"] as? String == HookMigration.legacyCommand(legacy,executable:new))
        #expect(hooks[0]["timeoutSeconds"] as? Int == 600)
        let repeated=try HookMigration.prepare(document:result.document,legacy:JSONEncoder().encode(legacy),startCommand:"",stopCommand:"",oldExecutable:old,newExecutable:new)
        #expect(repeated.changedHooks==0)
        #expect(repeated.document==result.document)
    }
    @Test("Empty lists never resurrect legacy export")
    func empty() throws {
        let input=Data("{\"version\":1,\"hooks\":[]}".utf8)
        let r=try HookMigration.prepare(document:input,legacy:JSONEncoder().encode(config()),startCommand:"echo old",stopCommand:"",oldExecutable:old,newExecutable:new)
        #expect(r.document==input)
        #expect(r.changedHooks==0)
    }
    @Test("Legacy-only settings import once with preserved disabled state")
    func initialImport() throws {
        let r=try HookMigration.prepare(document:nil,legacy:JSONEncoder().encode(config(false)),startCommand:"echo start",stopCommand:"echo end",oldExecutable:old,newExecutable:new)
        let json=try JSONSerialization.jsonObject(with:r.document) as! [String:Any]
        let hooks=json["hooks"] as! [[String:Any]]
        #expect(hooks.count==3)
        #expect(hooks[2]["enabled"] as? Bool == false)
        #expect(hooks[2]["command"] as? String == HookMigration.legacyCommand(config(false),executable:new))
    }
    @Test("Unknown versions, malformed documents and customized old calls are refused")
    func refuses() throws {
        for input in [Data("bad".utf8),Data("{\"version\":2,\"hooks\":[]}".utf8),try document(command:"'"+old+"' --notion-sync customized"),try document(command:HookMigration.quote(old)+" --notion-status")] {
            #expect(throws:(any Error).self) { try HookMigration.prepare(document:input,legacy:JSONEncoder().encode(config()),startCommand:"",stopCommand:"",oldExecutable:old,newExecutable:new) }
        }
    }
    @Test("Shell literals preserve paths and do not interpolate source")
    func quoting() throws {
        let legacy=config();let command=HookMigration.legacyCommand(legacy,executable:new)
        let output=try NotionCLI.run(executable:"/bin/sh",arguments:["-c","printf '%s\\n' "+command],timeout:2,environment:["SPLITVOX_SESSION_DIRECTORY":"/tmp/session'$(noop)","SPLITVOX_RECORDING_STARTED_AT":"2026-10-30T00:00:00Z"])
        let argv=String(decoding:output,as:UTF8.self).split(separator:"\n").map(String.init)
        #expect(argv == [new,"--notion-sync","/tmp/session'$(noop)","--write","--started-at","2026-10-30T00:00:00Z","--ntn",legacy.cliPath,"--parent-page",legacy.parentPageID,"--window-minutes","37.0"])
    }
    @Test("Unknown migration flags cannot accidentally select live default preferences")
    func unknownOptions() {
        #expect(throws: (any Error).self) { try HookMigration.run(["--migrate-local-hooks", "--domian", "isolated", "--write"]) }
    }

}
