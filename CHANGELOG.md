# Changelog

## latest (2022-06-06)

#### New Features

* (expo): support for google services file overrides ([#334](https://github.com/hamlet-io/executor-bash/issues/334))
#### Fixes

* script deprecation warning ([#332](https://github.com/hamlet-io/executor-bash/issues/332))
#### Refactorings

* changelog generation
#### Others

* changelog bump
* changelog bump

Full set of changes: [`8.6.0...latest`](https://github.com/hamlet-io/executor-bash/compare/8.6.0...latest)

## 8.6.0 (2022-05-24)

#### New Features

* detect existing images ([#326](https://github.com/hamlet-io/executor-bash/issues/326))
* add entrance output dir for imagedetails
* add HAMLET_EVENT_DIR
* event logging for write events
#### Fixes

* spelling in messages
* three level context properties ([#327](https://github.com/hamlet-io/executor-bash/issues/327))
#### Refactorings

* Add deprecation warnings for bash executor
* sort template objects
* scope settings search and remove legacy
* remove deprecated integrator commands
* remove blueprint doc generation
* remove reference to slices
* automation setContext updates

Full set of changes: [`8.5.0...8.6.0`](https://github.com/hamlet-io/executor-bash/compare/8.5.0...8.6.0)

## 8.5.0 (2022-03-25)

#### New Features

* add support for providing the district cli option to templates
* add docdb support ([#312](https://github.com/hamlet-io/executor-bash/issues/312))
* add support for bundled freemarker wrapper
#### Fixes

* district default handling
* sentry release cli support
* make output dir for binary only
* macos run_id and expo ouputs
#### Refactorings

* district rename to district type
* handling of bundled vs jar wrapper
* use weird seperate for user provided paramters
#### Others

* changelog bump ([#307](https://github.com/hamlet-io/executor-bash/issues/307))

Full set of changes: [`8.4.0...8.5.0`](https://github.com/hamlet-io/executor-bash/compare/8.4.0...8.5.0)

## 8.4.0 (2022-01-06)

#### New Features

* output handling for runbook entrances
* (lambda): add support for lambda jar registry
* log group retention control ([#300](https://github.com/hamlet-io/executor-bash/issues/300))
* split vpn tunnel configuration
* disable credential setup in automation
* remove location checks
#### Fixes

* sleep command formatting for compatability
* align azure auth envs with aws envs
* (cloudwatch): check for log group before retention update
* account state lookup
* osx differences for commands
* handle failed stack deletes
* (expo): fix sheild args for badge
* (expo): use correct args in badge config
* set ses active ruleset parameter substitution
* set default ses ruleset ([#293](https://github.com/hamlet-io/executor-bash/issues/293))
* revert deployment mode change
* (aws): make tunnel ip support bash arrays
* missing var ending
* env credential switching
* automation executor updates
* remove return from change set creation
* account directory for cmdb save
* handle existing tree search for account
* remove tag requirement
* (ci): generate changelog on tag
#### Refactorings

* show output on failed remote check
* azure deployment updates
* remove dos2unix
* always format commit message
* stack delete handling
#### Others

* changelog bump ([#279](https://github.com/hamlet-io/executor-bash/issues/279))
* remove copyright notice
* add a copyright and fix some typos
* changelog bump ([#233](https://github.com/hamlet-io/executor-bash/issues/233))

Full set of changes: [`8.3.0...8.4.0`](https://github.com/hamlet-io/executor-bash/compare/8.3.0...8.4.0)

## 8.3.0 (2021-09-10)

#### New Features

* adds a helper script to save cmdb updates
* stage repository commits
* set district on location in automation
* handle waf logging disable on delete ([#260](https://github.com/hamlet-io/executor-bash/issues/260))
* local run support and badge config check
* support for local runs
* add badges to app icons
* add simple api definition file name
* add support for deploying into local account
* handle none source and user defined config
* aws non auth source to bypass validation
* replace automation with standard script
* error on unknown provider
* azure login consolidation
* manage aws auth through profiles
#### Fixes

* errors on saving repo state
* (ssh): use a file when providing the key
* (sshkey): convert to sshkey pair for upload
* construct dirs and repo saving
* add defer to opts
* typo in app publish script
* add delete completion check
* handling of location context
* registry type definitions location ([#264](https://github.com/hamlet-io/executor-bash/issues/264))
* resetting of temporary file stack
* (docker): ecr repository lookup credentials
* credentials utility access
* aws role generation ([#257](https://github.com/hamlet-io/executor-bash/issues/257))
* variable scope for env config
* support legacy AWS account lookup
* testing updates
#### Refactorings

* remove egrep usage for stack status
* sentry release handling ([#259](https://github.com/hamlet-io/executor-bash/issues/259))
* (sentry): minor updates and react updates
* remove access key config integrator
* remove access key handling and reformat
* remove access key handling from context
* remove access key handling
* support generation credentials handling

Full set of changes: [`8.2.1...8.3.0`](https://github.com/hamlet-io/executor-bash/compare/8.2.1...8.3.0)

## 8.2.1 (2021-07-09)

#### New Features

* (ci): handle tag based releases ([#255](https://github.com/hamlet-io/executor-bash/issues/255))

Full set of changes: [`8.2.0...8.2.1`](https://github.com/hamlet-io/executor-bash/compare/8.2.0...8.2.1)

## 8.2.0 (2021-07-08)

#### New Features

* extend logging for invalid image formats
* (automation): support profiles for automation
* (automation): use an existing CMDB
* add the hamletcli automation provider
* handle react native bundle files in sentry ([#242](https://github.com/hamlet-io/executor-bash/issues/242))
* .cmdb directory
* add docker context handling
* user provided images
* stack management processing
* always check caller identity
* add check for aws account usage
* set SES active ruleset function ([#219](https://github.com/hamlet-io/executor-bash/issues/219))
* docker based packaging ([#217](https://github.com/hamlet-io/executor-bash/issues/217))
#### Fixes

* use pull for remote image s3 pulls
* remove stripping from context path for image
* typo in existing tree check
* typos and options cleanup
* handle older env vars for docker images
* registry handling for similar storage types
* tagging update for docker images
* (ci): docker and changelog
* correct SENTRY_SOURCE_MAP_S3_URL value ([#241](https://github.com/hamlet-io/executor-bash/issues/241))
* always update stack if no changes are found
* handle same tmp dir for multiple passes
* catch all updates to opts
* master branch references ([#232](https://github.com/hamlet-io/executor-bash/issues/232))
* typo
* exit handling
* allow for dockerfile override
* changelog generation
* update wording and fix install approach
* replace templates in manage stack
#### Refactorings

* use docker meta for tagging
* (ci): remove git dir from docker images
* align wrapper env with engine envs
* wrapper upgrade to 1.15.1 ([#235](https://github.com/hamlet-io/executor-bash/issues/235))
* engine install process updates
* (ci): updates from testing and ops
* use paths instead of files for dirs
* consolidate s3 zip registry files
* remove assemble settings from image pull
* remove jenkinsfile
* Remove build time openapi extension ([#220](https://github.com/hamlet-io/executor-bash/issues/220))
* dynamic cmdb plugin detection ([#218](https://github.com/hamlet-io/executor-bash/issues/218))
#### Others

* use hamlet cli release instead of pre

Full set of changes: [`8.1.2...8.2.0`](https://github.com/hamlet-io/executor-bash/compare/8.1.2...8.2.0)

## 8.1.2 (2021-05-13)

#### New Features

* yaml config output support
* filter contract steps based on status
* set key scope for out of repo crypto
* engine log formatting support
* move to using the latest freemarker wrapper
* pass outputfilename from gen contract ([#177](https://github.com/hamlet-io/executor-bash/issues/177))
* (util): aws vpn connection tunnel ip ([#175](https://github.com/hamlet-io/executor-bash/issues/175))
* add occurrences entrance support ([#174](https://github.com/hamlet-io/executor-bash/issues/174))
* set log level default
* engine status codes ([#168](https://github.com/hamlet-io/executor-bash/issues/168))
* (automation): add ref for account repos
* switch to v1.12.3 of the wrapper ([#166](https://github.com/hamlet-io/executor-bash/issues/166))
* whatif input source ([#156](https://github.com/hamlet-io/executor-bash/issues/156))
* (expo): set encryption exemption on upload ([#157](https://github.com/hamlet-io/executor-bash/issues/157))
* starting layers
* wrapper upgrade to 1.12.1 ([#154](https://github.com/hamlet-io/executor-bash/issues/154))
* (createTemplate): schemacontract outputs ([#151](https://github.com/hamlet-io/executor-bash/issues/151))
* non zip image url sourcing ([#148](https://github.com/hamlet-io/executor-bash/issues/148))
* changelog generation ([#147](https://github.com/hamlet-io/executor-bash/issues/147))
* account deployment unit region override
* plugin loading from contract ([#134](https://github.com/hamlet-io/executor-bash/issues/134))
* (docker): support pulling images during generation ([#141](https://github.com/hamlet-io/executor-bash/issues/141))
* Provider-specific account configuration should be determined from a provider-independent source
* (ec2): support for disabling scale in protection ([#136](https://github.com/hamlet-io/executor-bash/issues/136))
* (expo): support abi builds in android
* (utility): pull image from external source for registry ([#126](https://github.com/hamlet-io/executor-bash/issues/126))
* update fatalmandatory calls with variable validator
* allow for overrides of outputdir in deployments
* add conventional commit formatting ([#119](https://github.com/hamlet-io/executor-bash/issues/119))
* custom entrance parameters ([#120](https://github.com/hamlet-io/executor-bash/issues/120))
* make cache directory configurable
* add flows paramter
* documentsets
* Force all units to same commit
* Support shared build.json and shared_build.json ([#98](https://github.com/hamlet-io/executor-bash/issues/98))
* "Account" and fixed build scope ([#95](https://github.com/hamlet-io/executor-bash/issues/95))
* disable build logging by default
* installation of android sdk
* credential download for playstore key
* android sdk setup
* android build, sign, push for expo
* add property overrides
* explicit control on output cleanup
* (aws): add support for ecs account settings
* (plan): enable dryrun for azure deployments ([#82](https://github.com/hamlet-io/executor-bash/issues/82))
* support mgmt contract generation
* (ecs): add fargate platform support to runTask
* (filetranfer): security group management for filetransfer
* (expo): add major version to OTA path
* Branch based deployment plans ([#70](https://github.com/hamlet-io/executor-bash/issues/70))
* add waf logging utility
* (schema): fixed schema template load ([#73](https://github.com/hamlet-io/executor-bash/issues/73))
* (azure): disable login if cant access subscription ([#69](https://github.com/hamlet-io/executor-bash/issues/69))
* (schema): new template level - schema ([#66](https://github.com/hamlet-io/executor-bash/issues/66))
* add deployment groups
* Freemarker log level control ([#62](https://github.com/hamlet-io/executor-bash/issues/62))
* allow per publish turtle install ([#57](https://github.com/hamlet-io/executor-bash/issues/57))
* CMDB Upgrades via pinning ([#53](https://github.com/hamlet-io/executor-bash/issues/53))
* (azure): Support for credentials and consistent stack naming ([#44](https://github.com/hamlet-io/executor-bash/issues/44))
* (console): replace ssm document creation with cleanup ([#41](https://github.com/hamlet-io/executor-bash/issues/41))
* (ec2): volume encryption
* Include encoding scheme(s) in filenames
* Add content encoding metadata
* (aws): cli task for vpn options
* Bare workflow support
* (externalnetwork): vpn attachment lookup
* Re-encrypt and list cmk crypto operations
* (task): support multiple env var overrides
* (expo): clean keychains and node pkg support
#### Fixes

* rds snapshot wait process
* remove debug
* config file location in context
* (expo): reduce version code for android
* file condition for config
* handling for missing generation contract
* region in filenames ([#203](https://github.com/hamlet-io/executor-bash/issues/203))
* freemarker status code analysis ([#198](https://github.com/hamlet-io/executor-bash/issues/198))
* freemarker output redirection ([#197](https://github.com/hamlet-io/executor-bash/issues/197))
* reorder template error checks ([#195](https://github.com/hamlet-io/executor-bash/issues/195))
* command line options of pass alternative
* plugin refresh should ignore modules ([#190](https://github.com/hamlet-io/executor-bash/issues/190))
* repo url in changelog
* setup entrance parameters
* use raw params for entrances
* handling of wrapper arguments
* bash indirection bug ([#181](https://github.com/hamlet-io/executor-bash/issues/181))
* runtask lookup of subcomponent
* diagram file output naming ([#167](https://github.com/hamlet-io/executor-bash/issues/167))
* add a check for detached head
* typo
* freemarker wrapper write functions
* force Expo tool versions ([#161](https://github.com/hamlet-io/executor-bash/issues/161))
* url image updates ([#155](https://github.com/hamlet-io/executor-bash/issues/155))
* (expo): codesign variable names ([#153](https://github.com/hamlet-io/executor-bash/issues/153))
* (expo): control code sign id for ios ([#152](https://github.com/hamlet-io/executor-bash/issues/152))
* correct var for source build ref ([#145](https://github.com/hamlet-io/executor-bash/issues/145))
* (ec2): allow for word splitting on instances ([#138](https://github.com/hamlet-io/executor-bash/issues/138))
* support empy engine fragments
* git commi for builds ([#135](https://github.com/hamlet-io/executor-bash/issues/135))
* correct checked environment variables ([#127](https://github.com/hamlet-io/executor-bash/issues/127))
* include output dir in getopts
* custom entrance parameters ([#122](https://github.com/hamlet-io/executor-bash/issues/122))
* (sentry): set tmpdir variable ([#118](https://github.com/hamlet-io/executor-bash/issues/118))
* add get opts for new args
* explicitly set level fordefinition file ([#114](https://github.com/hamlet-io/executor-bash/issues/114))
* remove multimanfiest for turtle builds
* add specfic env var for turtle
* debug turtle build
* dir location check
* directory location lookup
* debug seg dir
* generation dir for build blueprint
* update blueprint file name for key ([#113](https://github.com/hamlet-io/executor-bash/issues/113))
* build blueprint setup script ([#111](https://github.com/hamlet-io/executor-bash/issues/111))
* expo build blueprint filename ([#109](https://github.com/hamlet-io/executor-bash/issues/109))
* tempalte cache creation ([#108](https://github.com/hamlet-io/executor-bash/issues/108))
* remove document set opt
* utility push
* push repo utility
* shared formats/scope checks
* Expose shared builds dir
* exit code for templates generation [#77](https://github.com/hamlet-io/executor-bash/issues/77) ([#99](https://github.com/hamlet-io/executor-bash/issues/99))
* ignore registry scope if not set ([#97](https://github.com/hamlet-io/executor-bash/issues/97))
* (ecs): handle failed task start and provide timeout for checks
* Make warning unique ([#93](https://github.com/hamlet-io/executor-bash/issues/93))
* Capture stack when change set fails
* More robust detection of stack completion ([#91](https://github.com/hamlet-io/executor-bash/issues/91))
* provide error handling for a malformed solution
* quotes for region
* (ecs): minor fix to use provided region
* (ecs): display effective value for validation of settings ([#88](https://github.com/hamlet-io/executor-bash/issues/88))
* expo update url
* ios dist password for cert
* src path for android build
* remove tree from debug
* use apk instead of aab
* output location
* binary path lookup
* debug output location for binary
* override output location for build
* remove s3 logs
* export for property setup
* declare config file prop
* decrypt property set
* remove null entry on lookup
* typo in property setup
* syntax error
* supress xcode output
* gradle args for quiet
* key alias
* logging default
* silent for pods install
* typo in silent output
* reinstate PR [#86](https://github.com/hamlet-io/executor-bash/issues/86)
* merge mixup
* remove dd status output for run id
* no subdirs when output dir is set
* include fragment composites for all input types
* move cache dir for non composite outputs
* No error when missing segment state dir ([#86](https://github.com/hamlet-io/executor-bash/issues/86))
* (run): lambda run not running with params ([#81](https://github.com/hamlet-io/executor-bash/issues/81))
* State tree deployment unit directory detection ([#79](https://github.com/hamlet-io/executor-bash/issues/79))
* include fragment composite in unitlist generation ([#78](https://github.com/hamlet-io/executor-bash/issues/78))
* removve QR message when its not required
* master ota location and log
* remove template lookup
* set fastlane manifest URL to build format specific version ([#67](https://github.com/hamlet-io/executor-bash/issues/67))
* assets path override ([#65](https://github.com/hamlet-io/executor-bash/issues/65))
* set assets url to an absolute value ([#64](https://github.com/hamlet-io/executor-bash/issues/64))
* Decoding on decryption ([#61](https://github.com/hamlet-io/executor-bash/issues/61))
* (expo): version source case statement ([#60](https://github.com/hamlet-io/executor-bash/issues/60))
* allow setting version source for expo builds ([#59](https://github.com/hamlet-io/executor-bash/issues/59))
* (expo): add try_repo_update_on_error parameter to fastlane run cocoapods
* env lookup for segment account ([#56](https://github.com/hamlet-io/executor-bash/issues/56))
* (logging): use debug level instead of trace
* (logging): align log levels with log4j2
* (setcontext): correct a mis-bracketted if-statement
* (testcases): dont cleanup output dir on mock
* (azure): use provider to set manage command ([#48](https://github.com/hamlet-io/executor-bash/issues/48))
* (azure): login method using service principal ([#47](https://github.com/hamlet-io/executor-bash/issues/47))
* azure credentials lookup ([#46](https://github.com/hamlet-io/executor-bash/issues/46))
* (azure): allow for running local deployments with context ([#45](https://github.com/hamlet-io/executor-bash/issues/45))
* (manageDeployment): tmpdir and tmp_dir to be equal
* Shared account/product/environment/segment names
* Fragment handling when composite cacheing enabled
* (expo): node package manager lookup
* Wrapper fix for CMDB file system
* (db): ensure db password resets are performed when required
* Default registry scope for manage images
* Fragment processing
* Make build target matching more precise
#### Refactorings

* support mulitpass executions
* support cmdb plugin ([#202](https://github.com/hamlet-io/executor-bash/issues/202))
* move exception handling to engine
* engine logging support for bash
* composite template inclusion ([#189](https://github.com/hamlet-io/executor-bash/issues/189))
* remove startup script support
* sort json objects for comparisons ([#182](https://github.com/hamlet-io/executor-bash/issues/182))
* only get credentials when required
* log level comparison
* move github templates to org ([#169](https://github.com/hamlet-io/executor-bash/issues/169))
* try and always populate cmdb root dir ([#158](https://github.com/hamlet-io/executor-bash/issues/158))
* handle missing plugin in setup ([#150](https://github.com/hamlet-io/executor-bash/issues/150))
* remove tagging of accounts cmdb ([#131](https://github.com/hamlet-io/executor-bash/issues/131))
* remove cmdb tagging ([#129](https://github.com/hamlet-io/executor-bash/issues/129))
* (waflogs): lookup ARN from cfn output ([#125](https://github.com/hamlet-io/executor-bash/issues/125))
* align template generation with new names
* definition filename function global
* separate function to get openapi defn
* check if directory is set instead of location
* switch COT to Hamlet ([#106](https://github.com/hamlet-io/executor-bash/issues/106))
* remove model in favour of flows
* support entrance for all template commands
* Support for entrances and deployment grp
* scope/formats from shared build ([#96](https://github.com/hamlet-io/executor-bash/issues/96))
* add function for property setup
* replace script with cfn account template
* consolidate entrypoints to freemarker
* Avoid duplicate unit listing ([#52](https://github.com/hamlet-io/executor-bash/issues/52))
* Reasonable defaults for CMK listing ([#49](https://github.com/hamlet-io/executor-bash/issues/49))
* More robust crypto options and s3 syncing
#### Docs

* overhaul of the README ([#171](https://github.com/hamlet-io/executor-bash/issues/171))
#### Others

* changelog update
* (deps): bump lodash from 4.17.20 to 4.17.21 ([#216](https://github.com/hamlet-io/executor-bash/issues/216))
* (deps): bump hosted-git-info from 2.8.8 to 2.8.9 ([#214](https://github.com/hamlet-io/executor-bash/issues/214))
* (deps): bump handlebars from 4.7.6 to 4.7.7 ([#213](https://github.com/hamlet-io/executor-bash/issues/213))
* remove suggestion that you can set resource group value
* remove resource groups from template passes
* release notes update
* changelog
* changelog
