import { ref, type Ref } from 'vue'
import {
  repositoryDiffStats,
  terminalPanesForTask,
  type AppState,
  type RepositoryDiffStats,
} from '../app-state/app-state'

const REFRESH_DELAY = 200

export function useRepositoryDiffStats(appState: Ref<AppState>) {
  const stats = ref<Record<string, RepositoryDiffStats>>({})
  const loading = ref<Record<string, boolean>>({})
  const timers = new Map<string, number>()
  const inFlight = new Set<string>()
  const refreshAgain = new Set<string>()

  function currentTaskRepo(taskRepoId: string) {
    return appState.value.tasks
      .flatMap((task) => task.repos)
      .find((repo) => repo.id === taskRepoId)
  }

  function remove(taskRepoId: string) {
    const { [taskRepoId]: _removed, ...remaining } = stats.value
    stats.value = remaining
  }

  function setLoading(taskRepoId: string, value: boolean) {
    const { [taskRepoId]: _removed, ...remaining } = loading.value
    loading.value = value ? { ...remaining, [taskRepoId]: true } : remaining
  }

  async function refresh(taskRepoId: string) {
    if (inFlight.has(taskRepoId)) {
      refreshAgain.add(taskRepoId)
      return
    }

    const taskRepo = currentTaskRepo(taskRepoId)

    if (!taskRepo?.worktreePath) {
      remove(taskRepoId)
      setLoading(taskRepoId, false)
      return
    }

    const worktreePath = taskRepo.worktreePath
    inFlight.add(taskRepoId)

    try {
      const nextStats = await repositoryDiffStats(worktreePath)
      const current = currentTaskRepo(taskRepoId)

      if (current?.worktreePath === worktreePath) {
        stats.value = { ...stats.value, [taskRepoId]: nextStats }
      }
    } catch {
      remove(taskRepoId)
    } finally {
      inFlight.delete(taskRepoId)
      setLoading(taskRepoId, false)

      if (refreshAgain.delete(taskRepoId)) {
        queue(taskRepoId, 0)
      }
    }
  }

  function queue(taskRepoId: string, delay = REFRESH_DELAY) {
    const existingTimer = timers.get(taskRepoId)

    if (existingTimer !== undefined) {
      window.clearTimeout(existingTimer)
    }

    if (!stats.value[taskRepoId]) {
      setLoading(taskRepoId, true)
    }

    timers.set(
      taskRepoId,
      window.setTimeout(() => {
        timers.delete(taskRepoId)
        void refresh(taskRepoId)
      }, delay),
    )
  }

  function queueForTerminalSession(sessionId: string) {
    for (const task of appState.value.tasks) {
      const directRepo = task.repos.find((repo) => repo.id === sessionId)

      if (directRepo) {
        queue(directRepo.id)
        return
      }

      const pane = terminalPanesForTask(task).find((item) => item.sessionId === sessionId)

      if (pane?.source.kind === 'repo') {
        queue(pane.source.taskRepoId)
        return
      }
    }
  }

  function refreshAll() {
    for (const task of appState.value.tasks) {
      task.repos.forEach((repo) => queue(repo.id, 0))
    }
  }

  function dispose() {
    timers.forEach((timer) => window.clearTimeout(timer))
    timers.clear()
  }

  return { stats, loading, queue, queueForTerminalSession, refreshAll, dispose }
}
