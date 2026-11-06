/* Public release projection only. No tracker export or private telemetry. */
window.__STATUS = {
  schemaVersion: 1,
  updatedAt: "2026-11-06T15:48:34Z",
  milestones: [
    { name: "Public sources", status: "passed", progress: null },
    { name: "PublicRelease build", status: "passed", progress: null },
    { name: "Cold hosted Windows CI", status: "passed", progress: null },
    { name: "Preview ZIP publication", status: "passed", progress: null }
  ],
  project: {
    repositories: {
      shell: "https://github.com/KldsSeeGhosts/caelestia-windows",
      quickshell: "https://github.com/KldsSeeGhosts/caelestia-quickshell-windows",
      glazier: "https://github.com/KldsSeeGhosts/glazier"
    },
    code: {
      sourceCommit: "699746045da7426c9df3e7baa85dc2d8d90b4f19"
    },
    release: {
      channel: "preview",
      platform: "Windows 11 x64",
      signed: false,
      binaryPublished: true,
      releasesUrl: "https://github.com/KldsSeeGhosts/caelestia-windows/releases/tag/v0.1.0-preview.2",
      limitationsUrl: "https://github.com/KldsSeeGhosts/caelestia-windows/blob/main/windows/docs/KNOWN-LIMITATIONS.md"
    },
    validation: {
      publicRecursiveClone: "passed",
      publicReleaseBuild: "passed",
      coldHostedCi: {
        status: "passed",
        url: "https://github.com/KldsSeeGhosts/caelestia-windows/actions/runs/42186767684",
        duration: "11m 49s"
      },
      cachedHostedCi: {
        status: "passed",
        url: "https://github.com/KldsSeeGhosts/caelestia-windows/actions/runs/42188301209",
        duration: "10m 55s"
      },
      finalHostedCi: {
        status: "passed",
        url: "https://github.com/KldsSeeGhosts/caelestia-windows/actions/runs/42243987117",
        duration: "10m 55s"
      }
    }
  }
};
