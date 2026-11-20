本项目（**ReRan's Customlizations - aka - RRC**）是作者作为个人魔兽世界玩家，根据自身对插件功能的理解和需求而开发的一款自定义插件，旨在添加一些简单的功能到游戏中。

## 当前功能（2026年11月17日）:

1. **DK自动血沸监视**：监视沸点触发，并使用一个计时条提醒是否有沸点血沸即将来临。

2. **姓名板Debuff监测**：基于对姓名板信息的获取，实现显示有多少敌方单位正受您目前监控的debuff（如dot）的影响。

3. **标记分配**：在所有安装了RRC的玩家中同步信息，以为每位玩家分配不同的焦点标记，需配合RRC自动创建的`RRC-TM`宏使用。使用该宏会让您在小队（或团队，当您开启该选项）中通报您当前设置焦点的单位，并进行标记。标记的原则是不覆盖任何已有的标记（如怪物1被标记了骷髅，您的标记是星星，该宏不会覆盖骷髅），但您可以勾选“覆盖已有标记”，以让该宏覆盖标记。本设置为角色设置，但`RRC-TM`为账号通用宏。

4. **隐藏bigwigs计时**：由于EXBOSS的屏幕中心信息有点不美观，而bigwigs又不具有大秘境小怪技能时间轴，故设计本功能。本功能旨在大秘境战斗中隐藏bigwigs计时条（包含由ability timeline/better timeline接管的bigwigs计时条），进而保留EXBOSS计时条及bigwigs重要技能文字提醒；同时在团队副本中屏蔽EXBOSS计时条，进而完全使用bigwigs实现战斗提示。启用后，bigwigs计时条会在地下城和团队副本中都被隐藏，勾选“仅在地下城中关闭计时条”后，团队副本内，bigwigs计时条不再被关闭。本设置为账号通用。

5. **集合石屏蔽**：本功能旨在实现集合石队名关键字实现集合石屏蔽。但由于it's secret改动，对于关键字的识别必须在游戏外实现。本功能的使用方式为：打开集合石，刷新一次后打开RRC，读取列表。 使用外部程序将所有列表页面截图保存，之后使用`RRC_MS`程序，通过调用您的windows ocr实现关键字识别筛选，`RRC_MS`会为您返回一个字符串，在游戏内的RRC导入该字符串，会按照对应的队长名实现屏蔽。

6. **自定义冷却管理器音效**：开启本功能后，您可以在游戏内自带的冷却管理器（Cooldown manager,`/CDM`）的添加音效提示中，选择您已经加载到游戏内的任何音效，而不限于原本的少数可选音效。（例如，您可以对嗜血BUFF设置一个激情澎湃的媒体）本设置为账号通用。

7. **队友打断监视**：以计时条形式监视队友打断CD。本功能受限于it's secret改动，只有当队友打断成功时才会开始CD计时（对于自己的玩家角色无此问题）。该功能的实现中，“使用暴雪伤害统计”来验证打断成功的思路源自Kira UI. 本设置为账号通用。

8. **自动邀请**：当选定的频道中有玩家发送了您自定义的字符串后，您会自动邀请该角色加入您的队伍或团队。本设置为账号通用。

9. **CDM颜色管理**：支持原生 CDM 重要/效能技能及 vFlow 技能分组，可独立开启 Buff 高亮、遮罩进度反转和颜色覆盖。高亮默认触发发光，视觉上可令您的冷却监视器中的技能对应Buff显示更接近右上原生Buff触发。本设置为账号通用。

---

在游戏中，您可以通过`/rrc`来显示配置面板。设置按以下范围保存：

- **账号通用**：功能4（隐藏bigwigs计时）、6（自定义冷却管理器音效）、7（队友打断监视）、8（自动邀请）、9（CDM颜色管理）。同一账号下的角色共用这些功能的 RRC 设置。
- **角色独立**：功能1（DK自动血沸监视）、2（姓名板Debuff监测）、3（标记分配）、5（集合石屏蔽）。
- 功能3的设置按角色保存，但新建的 `RRC-TM` 宏为**账号通用宏**；宏的保存范围不等于该功能设置的保存范围。
- 功能6、9的账号共享范围仅指 RRC 自身设置，不会改变暴雪 CDM 或 vFlow 的布局、技能列表和提醒配置的保存范围。

账号通用功能首次迁移旧角色设置时，仅在对应账号设置尚不存在的情况下继承当前角色设置；后续角色不会覆盖已有账号设置。

本项目是一个纯粹由AI实现的项目，对于代码的实现合理度与精简度未做任何审查。

本人只保证构建代码与功能测试的过程未人为添加任何可能涉及您隐私、账号信息获取的功能。

使用过程中，对于您的魔兽世界插件库，账号或角色配置造成的任何影响无法负责。（当前该情况可能出现于EXBOSS+BIGWIGS组合隐藏功能中，若您有此方面的担忧，请放弃使用该功能或对账号配置、角色配置进行备份）

对于打断监视功能，个人持保守态度（上传者认为当前的secret化是意在屏蔽本项功能，或者说，本项功能的实现在一定程度上绕过了原本不该获取到的事件），故进行的测试与修改较少。

由于有限的游玩时间，作者可能无法及时更新本插件。届时，请自行用AI解决或fork本项目。

另外，您也可以任意复制本项目的任何思路或实现方式到您的开发中。

感谢您的使用，若遇到问题可在Issue中反馈，但作者无法保证回答的频率，也无法保证您期望的修改在当前的插件环境中能够实现。

---

> we don't currently offer an english version of ui though, feel free to translate yourself

This project (**ReRan's Customlizations - aka - RRC**) is a custom addon developed by the author as an individual World of Warcraft player, based on their own understanding of and needs for addon functionality, with the aim of adding some simple features to the game.

## Current features (November 17, 2026):

1. **DK automatic Blood Boil monitoring**: Monitors Boiling Point procs and uses a timer bar to indicate whether a Boiling Point Blood Boil is coming up.

2. **Nameplate debuff monitoring**: Uses information obtained from nameplates to display how many enemy units are currently affected by the debuffs you are monitoring (such as DoTs).

3. **Marker assignment**: Synchronizes information among all players with RRC installed to assign each player a different focus marker. This requires using the `RRC-TM` macro automatically created by RRC. Using this macro announces your current focus target to your party (or raid, if you enable that option) and marks it. By default, marking does not overwrite any existing markers (for example, if enemy 1 is marked with a skull and your marker is a star, the macro will not overwrite the skull), but you can check “Overwrite existing markers” to allow the macro to overwrite markers. Settings are saved per character, but `RRC-TM` is an account-wide macro.

4. **Hide bigwigs timers**: This feature was designed because EXBOSS's information in the center of the screen is somewhat unattractive, while bigwigs does not have a Mythic+ trash ability timeline. The feature is intended to hide bigwigs timer bars during Mythic+ combat (including bigwigs timer bars managed by ability timeline/better timeline), retaining EXBOSS timer bars and bigwigs text alerts for important abilities; meanwhile, it hides EXBOSS timer bars in raids so that combat alerts are handled entirely by bigwigs. When enabled, bigwigs timer bars are hidden in both dungeons and raids. After checking “Disable timer bars only in dungeons,” bigwigs timer bars will no longer be disabled in raids. Settings are account-wide.

5. **Meeting Stone blocking**: This feature is intended to block Meeting Stone groups based on keywords in group names. However, due to the it's secret changes, keyword recognition must be performed outside the game. To use this feature: open Meeting Stone, refresh once, then open RRC and read the list. Use an external program to capture and save screenshots of all list pages, then use the `RRC_MS` program to recognize and filter keywords through your windows ocr. `RRC_MS` will return a string; importing that string into RRC in-game will block entries based on the corresponding group leaders' names.

6. **Custom Cooldown Manager sounds**: After enabling this feature, when adding sound alerts in the game's built-in Cooldown Manager (Cooldown manager,`/CDM`), you can select any sound you have loaded into the game, rather than being limited to the few original options. (For example, you can assign an energetic media clip to the Bloodlust buff.) Settings are account-wide.

7. **Teammate interrupt monitoring**: Monitors teammates' interrupt cooldowns using timer bars. This feature is limited by the it's secret changes: cooldown tracking begins only when a teammate successfully interrupts (this limitation does not apply to your own player character). In the implementation of this feature, the idea of “using Blizzard's damage statistics” to verify successful interrupts came from Kira UI. Settings are account-wide.

8. **Automatic invitations**: When a player sends your custom string in a selected channel, you automatically invite that character to your party or raid. Settings are account-wide.

9. **CDM color management**: Supports native CDM Essential/Utility abilities and vFlow ability groups, with independently enabled buff highlighting, cooldown swipe reversal, and color override options. Highlighting uses a proc glow by default, making the corresponding buff indicators in your cooldown viewers look more like the native buff procs in the top-right corner. Settings are account-wide.

---

Use `/rrc` in-game to open the configuration panel. Settings are saved with the following scopes:

- **Account-wide**: Features 4 (Hide bigwigs timers), 6 (Custom Cooldown Manager sounds), 7 (Teammate interrupt monitoring), 8 (Automatic invitations), and 9 (CDM color management). Characters on the same account share these RRC settings.
- **Per-character**: Features 1 (DK automatic Blood Boil monitoring), 2 (Nameplate debuff monitoring), 3 (Marker assignment), and 5 (Meeting Stone blocking).
- Feature 3 saves its settings per character, but newly created `RRC-TM` macros are **account-wide macros**. Macro scope and feature settings scope are separate.
- Account-wide sharing for features 6 and 9 applies only to RRC's own settings; it does not change how Blizzard CDM or vFlow saves layouts, tracked spell lists, or alert configurations.

When migrating legacy per-character settings for an account-wide feature, the current character's settings are inherited only if that feature has no account settings yet. Subsequent characters do not overwrite existing account settings.

This project was implemented entirely by AI. No review has been conducted of the code's implementation quality or conciseness.

I only guarantee that no functionality potentially involving access to your private data or account information was manually added during the code-building and feature-testing process.

I cannot take responsibility for any effects on your World of Warcraft addon library, account settings, or character settings during use. (Currently, this situation may arise with the combined EXBOSS+BIGWIGS hiding feature. If you are concerned about this, please refrain from using that feature or back up your account and character settings)

I personally take a cautious stance toward the interrupt monitoring feature (the uploader believes that the current move toward secret values is intended to block this feature, or that its implementation bypasses, to some extent, events that should not have been accessible in the first place), so relatively little testing and modification have been done.

Due to limited playtime, the author may be unable to update this addon promptly. If that happens, please use AI to resolve issues yourself or fork this project.

Feel free to copy any ideas or implementation approaches from this project into your own development.

Thank you for using this addon. If you encounter problems, you can report them in an Issue, but the author cannot guarantee how frequently they will respond, nor that the changes you hope for can be implemented in the current addon environment.
