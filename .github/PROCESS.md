# Automation Process

## Project Sync

### Global Project

All open issues from every non-archived repo in the `metatrom-ag` org are automatically added to the **Metatrom Global** project (#6). Issues without a Status are set to **Inbox**.

### Name Convention Sync

To have a repo's issues also synced into a specific project, name the project **exactly the same as the repo** (case-sensitive).

Examples:
- Repo `Ai-Hub` → issues added to project `Ai-Hub` (#11) **and** Global
- Repo `metatrom` → issues added to project `metatrom` (#18) **and** Global
- Repo `oasis` → no project named `oasis` → Global only

No configuration needed. The daily sync reads all org project names and matches by name automatically.

### Ontocratic Requirement

Only projects with **Purpose**, **Intention**, and **Action** status options participate in name-convention sync. Personal, untitled, or template projects are skipped even if their name matches a repo.

### Inbox

All issues added by automation start in **Inbox** status. Existing items without a status are also set to Inbox on each run.

### Schedule

- **05:00 UTC daily** — project sync (`sync-global-project.yml`)
- **06:00 UTC daily** — dashboard update (`update-private-dashboard.yml`)

The sync runs 1 hour before the dashboard so the dashboard always reflects complete data.

## Adding a New Project to the Convention

1. Create a GitHub Project in the `metatrom-ag` org.
2. Name it exactly the same as the repo (case-sensitive).
3. Ensure it has **Inbox**, **Purpose**, **Intention**, and **Action** as Status options.
4. Done — the next daily sync will start adding issues automatically.
