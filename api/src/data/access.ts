import type { Row } from "./rows";

export type Role = "owner" | "editor" | "viewer";

/** Answers "may this user see / change that record" with one membership query per request. */
export class Access {
  private roles?: Map<string, Role>;

  constructor(
    private readonly db: D1Database,
    readonly userId: string,
  ) {}

  /** Roles in projects that still exist. */
  async memberships(): Promise<Map<string, Role>> {
    if (!this.roles) {
      const { results } = await this.db
        .prepare(
          `SELECT m.project_id, m.role FROM project_members m
           JOIN projects p ON p.id = m.project_id
           WHERE m.user_id = ? AND p.deleted_at IS NULL`,
        )
        .bind(this.userId)
        .all<{ project_id: string; role: Role }>();
      this.roles = new Map(results.map((r) => [r.project_id, r.role]));
    }
    return this.roles;
  }

  /** Call after a write that changes memberships. */
  invalidate() {
    this.roles = undefined;
  }

  async role(projectId: string): Promise<Role | null> {
    return (await this.memberships()).get(projectId) ?? null;
  }

  async canEditProject(projectId: string): Promise<boolean> {
    const role = await this.role(projectId);
    return role === "owner" || role === "editor";
  }

  /** Whether a task's location (project or inbox) is readable. */
  async canSeeTask(task: Row): Promise<boolean> {
    if (task.project_id == null) return task.owner_id === this.userId;
    return (await this.role(task.project_id as string)) !== null;
  }

  async canEditTask(task: Row): Promise<boolean> {
    if (task.project_id == null) return task.owner_id === this.userId;
    return this.canEditProject(task.project_id as string);
  }
}
