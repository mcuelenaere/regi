#!/usr/bin/env python3
"""Generate Probe/RegiProbe.xcodeproj from the files on disk.

Regi.xcodeproj is hand-maintained, which means every new source file has to be
added to a group and a build phase by hand. There is no reason to inherit that
cost here: this scans Probe/RegiProbe for sources and emits the pbxproj, so
adding a file is just adding a file.

Object IDs are derived from a hash of each path, so the output is byte-stable
across runs and diffs stay readable.

    ./Probe/generate_project.py
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
APP_DIR = ROOT / "RegiProbe"
PROJECT = ROOT / "RegiProbe.xcodeproj"
BUNDLE_ID = "app.regi.probe"
DEPLOYMENT_TARGET = "14.0"


def oid(*parts: str) -> str:
    """Deterministic 24-hex-digit object id, the shape Xcode expects."""
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:24].upper()


def collect_sources():
    return sorted(
        p.relative_to(APP_DIR).as_posix()
        for p in APP_DIR.rglob("*.swift")
    )


def build(sources):
    L = []
    add = L.append

    file_refs = {s: oid("fileref", s) for s in sources}
    build_files = {s: oid("buildfile", s) for s in sources}
    plist_ref = oid("fileref", "Info.plist")
    product_ref = oid("product")
    target_id = oid("target")
    project_id = oid("project")
    main_group = oid("group", "")
    products_group = oid("group", "Products")
    sources_phase = oid("phase", "sources")
    frameworks_phase = oid("phase", "frameworks")
    resources_phase = oid("phase", "resources")
    target_cfg_list = oid("cfglist", "target")
    project_cfg_list = oid("cfglist", "project")
    pkg_ref = oid("pkgref", "ProbeKit")
    pkg_product = oid("pkgproduct", "ProbeKit")
    pkg_buildfile = oid("buildfile", "ProbeKit")

    # Directory groups, so the Xcode navigator mirrors the folder layout.
    dirs = sorted({str(pathlib.PurePosixPath(s).parent) for s in sources})
    dirs = [d for d in dirs if d != "."]
    dir_groups = {d: oid("group", d) for d in dirs}

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 63;")
    add("\tobjects = {")

    add("\n/* Begin PBXBuildFile section */")
    for s in sources:
        add(f"\t\t{build_files[s]} /* {pathlib.PurePosixPath(s).name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_refs[s]} /* {pathlib.PurePosixPath(s).name} */; }};")
    add(f"\t\t{pkg_buildfile} /* ProbeKit in Frameworks */ = "
        f"{{isa = PBXBuildFile; productRef = {pkg_product} /* ProbeKit */; }};")
    add("/* End PBXBuildFile section */")

    add("\n/* Begin PBXFileReference section */")
    for s in sources:
        name = pathlib.PurePosixPath(s).name
        add(f"\t\t{file_refs[s]} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
    add(f"\t\t{plist_ref} /* Info.plist */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    add(f"\t\t{product_ref} /* RegiProbe.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = RegiProbe.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    add("/* End PBXFileReference section */")

    add("\n/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase} = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add(f"\t\t\t\t{pkg_buildfile} /* ProbeKit in Frameworks */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")

    add("\n/* Begin PBXGroup section */")
    root_files = [s for s in sources if "/" not in s]
    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{oid('group', 'RegiProbe')} /* RegiProbe */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{oid('group', 'RegiProbe')} /* RegiProbe */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for s in root_files:
        add(f"\t\t\t\t{file_refs[s]} /* {pathlib.PurePosixPath(s).name} */,")
    for d in dirs:
        add(f"\t\t\t\t{dir_groups[d]} /* {d} */,")
    add(f"\t\t\t\t{plist_ref} /* Info.plist */,")
    add("\t\t\t);")
    add("\t\t\tpath = RegiProbe;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    for d in dirs:
        add(f"\t\t{dir_groups[d]} /* {d} */ = {{")
        add("\t\t\tisa = PBXGroup;")
        add("\t\t\tchildren = (")
        for s in sources:
            if str(pathlib.PurePosixPath(s).parent) == d:
                add(f"\t\t\t\t{file_refs[s]} /* {pathlib.PurePosixPath(s).name} */,")
        add("\t\t\t);")
        add(f"\t\t\tpath = {d};")
        add("\t\t\tsourceTree = \"<group>\";")
        add("\t\t};")

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_ref} /* RegiProbe.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("/* End PBXGroup section */")

    add("\n/* Begin PBXNativeTarget section */")
    add(f"\t\t{target_id} /* RegiProbe */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {target_cfg_list};")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase},")
    add(f"\t\t\t\t{frameworks_phase},")
    add(f"\t\t\t\t{resources_phase},")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add("\t\t\t);")
    add("\t\t\tname = RegiProbe;")
    add("\t\t\tpackageProductDependencies = (")
    add(f"\t\t\t\t{pkg_product} /* ProbeKit */,")
    add("\t\t\t);")
    add("\t\t\tproductName = RegiProbe;")
    add(f"\t\t\tproductReference = {product_ref} /* RegiProbe.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")
    add("/* End PBXNativeTarget section */")

    add("\n/* Begin PBXProject section */")
    add(f"\t\t{project_id} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target_id} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {project_cfg_list};")
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    add("\t\t\t\ten,")
    add("\t\t\t\tBase,")
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group};")
    add("\t\t\tminimizedProjectReferenceProxies = 1;")
    add("\t\t\tpackageReferences = (")
    add(f"\t\t\t\t{pkg_ref} /* XCLocalSwiftPackageReference \"../Packages/ProbeKit\" */,")
    add("\t\t\t);")
    add(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{target_id} /* RegiProbe */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")

    add("\n/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase} = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")

    add("\n/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase} = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for s in sources:
        add(f"\t\t\t\t{build_files[s]} /* {pathlib.PurePosixPath(s).name} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")

    def config(name, oid_, target):
        add(f"\t\t{oid_} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        if target:
            add("\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;")
            add("\t\t\t\tCODE_SIGN_IDENTITY = \"-\";")
            add("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
            add("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
            add("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
            add("\t\t\t\tENABLE_HARDENED_RUNTIME = YES;")
            # No App Sandbox key on purpose: the sandbox blocks session event
            # taps outright, which is the probe's only means of capture.
            add("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
            add("\t\t\t\tINFOPLIST_FILE = RegiProbe/Info.plist;")
            add("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
            add("\t\t\t\t\t\"$(inherited)\",")
            add("\t\t\t\t\t\"@executable_path/../Frameworks\",")
            add("\t\t\t\t);")
            add(f"\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};")
            add("\t\t\t\tMARKETING_VERSION = 0.1;")
            add(f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};")
            add("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
            add("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
            add("\t\t\t\tSWIFT_VERSION = 5.0;")
        else:
            add("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
            add("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
            add("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
            add("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
            add(f"\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};")
            add("\t\t\t\tSDKROOT = macosx;")
            if name == "Debug":
                add("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
                add("\t\t\t\tENABLE_TESTABILITY = YES;")
                add("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
                add("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
                add("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";")
                add("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
            else:
                add("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
                add("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
                add("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
        add("\t\t\t};")
        add(f"\t\t\tname = {name};")
        add("\t\t};")

    add("\n/* Begin XCBuildConfiguration section */")
    for name in ("Debug", "Release"):
        config(name, oid("cfg", "project", name), target=False)
        config(name, oid("cfg", "target", name), target=True)
    add("/* End XCBuildConfiguration section */")

    add("\n/* Begin XCConfigurationList section */")
    for label, list_id, prefix in (("PBXProject", project_cfg_list, "project"),
                                   ("PBXNativeTarget", target_cfg_list, "target")):
        add(f"\t\t{list_id} /* Build configuration list for {label} */ = {{")
        add("\t\t\tisa = XCConfigurationList;")
        add("\t\t\tbuildConfigurations = (")
        add(f"\t\t\t\t{oid('cfg', prefix, 'Debug')} /* Debug */,")
        add(f"\t\t\t\t{oid('cfg', prefix, 'Release')} /* Release */,")
        add("\t\t\t);")
        add("\t\t\tdefaultConfigurationIsVisible = 0;")
        add("\t\t\tdefaultConfigurationName = Release;")
        add("\t\t};")
    add("/* End XCConfigurationList section */")

    add("\n/* Begin XCLocalSwiftPackageReference section */")
    add(f"\t\t{pkg_ref} /* XCLocalSwiftPackageReference \"../Packages/ProbeKit\" */ = {{")
    add("\t\t\tisa = XCLocalSwiftPackageReference;")
    add("\t\t\trelativePath = ../Packages/ProbeKit;")
    add("\t\t};")
    add("/* End XCLocalSwiftPackageReference section */")

    add("\n/* Begin XCSwiftPackageProductDependency section */")
    add(f"\t\t{pkg_product} /* ProbeKit */ = {{")
    add("\t\t\tisa = XCSwiftPackageProductDependency;")
    add("\t\t\tproductName = ProbeKit;")
    add("\t\t};")
    add("/* End XCSwiftPackageProductDependency section */")

    add("\t};")
    add(f"\trootObject = {project_id} /* Project object */;")
    add("}")
    return "\n".join(L) + "\n"


def scheme(name="RegiProbe"):
    target_id = oid("target")
    project_id = oid("project")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{name}.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{name}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def main():
    sources = collect_sources()
    if not sources:
        sys.exit(f"no Swift sources under {APP_DIR}")
    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(build(sources))
    shared = PROJECT / "xcshareddata" / "xcschemes"
    shared.mkdir(parents=True, exist_ok=True)
    (shared / "RegiProbe.xcscheme").write_text(scheme())
    print(f"Generated {PROJECT} with {len(sources)} sources")


if __name__ == "__main__":
    main()
