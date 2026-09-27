/// Who or what a command is about: a spoken name (matched on the phone),
/// or an exact reference (from the brain, whose short ids the phone maps
/// back). Always checked against the current [GuideWorld] before acting.
sealed class GuideRef {
  const GuideRef();
}

/// A name as spoken: an agent, project or machine.
class GuideByName extends GuideRef {
  const GuideByName(this.name);

  final String name;
}

class GuideAgentRef extends GuideRef {
  const GuideAgentRef(this.hostId, this.agentId);

  final String hostId;
  final String agentId;
}

class GuideMachineRef extends GuideRef {
  const GuideMachineRef(this.hostId);

  final String hostId;
}

/// Every agent working in [project] (a repository name).
class GuideProjectRef extends GuideRef {
  const GuideProjectRef(this.project);

  final String project;
}

class GuideRequestRef extends GuideRef {
  const GuideRequestRef(this.hostId, this.requestId);

  final String hostId;
  final String requestId;
}

/// One thing the user asked for. [GuidePhrases] makes these from common
/// phrases; the brain's answer becomes one too.
sealed class GuideIntent {
  const GuideIntent();

  /// Needs a spoken "yes" first (subject to the settings and risk).
  bool get risky => false;
}

/// "What's waiting": pending approvals, questions and idle agents.
class GuideWhatsWaiting extends GuideIntent {
  const GuideWhatsWaiting();
}

class GuideOpen extends GuideIntent {
  const GuideOpen(this.target);

  final GuideRef target;
}

/// Show an agent (null: the one on screen) in Chat View.
class GuideShowChat extends GuideIntent {
  const GuideShowChat([this.target]);

  final GuideRef? target;
}

/// Show an agent (null: the one on screen) in its terminal.
class GuideShowTerminal extends GuideIntent {
  const GuideShowTerminal([this.target]);

  final GuideRef? target;
}

/// Approve ([allow]) or deny one request: [target] names it, or its agent;
/// null means the agent on screen, or the only request waiting.
class GuideDecide extends GuideIntent {
  const GuideDecide({required this.allow, this.target});

  final bool allow;
  final GuideRef? target;

  @override
  bool get risky => true;
}

class GuideApproveAllSafe extends GuideIntent {
  const GuideApproveAllSafe();

  @override
  bool get risky => true;
}

class GuideTrust extends GuideIntent {
  const GuideTrust(this.minutes, [this.target]);

  final int minutes;
  final GuideRef? target;

  @override
  bool get risky => true;
}

/// "Tell an agent to do something": [text] goes to it as a prompt.
class GuideSend extends GuideIntent {
  const GuideSend(this.target, this.text);

  final GuideRef target;
  final String text;

  @override
  bool get risky => true;
}

/// Read an agent's last reply (null: the one on screen).
class GuideRead extends GuideIntent {
  const GuideRead([this.target]);

  final GuideRef? target;
}

/// The rest of what was read briefly.
class GuideMore extends GuideIntent {
  const GuideMore();
}

/// Stop talking and listening.
class GuideStop extends GuideIntent {
  const GuideStop();
}

class GuideHome extends GuideIntent {
  const GuideHome();
}

class GuideUsage extends GuideIntent {
  const GuideUsage();
}

class GuideHelp extends GuideIntent {
  const GuideHelp();
}

/// "Switch to an account" (Claude account switching, when available).
class GuideSwitchAccount extends GuideIntent {
  const GuideSwitchAccount(this.account);

  final String account;

  @override
  bool get risky => true;
}

/// Only speak (the brain's answer to a question, or why it did nothing).
class GuideSay extends GuideIntent {
  const GuideSay(this.text);

  final String text;
}
