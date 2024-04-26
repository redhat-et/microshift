package build

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"

	"github.com/openshift/microshift/test/pkg/compose/templatingdata"
	"github.com/openshift/microshift/test/pkg/testutil"
	"k8s.io/klog/v2"
)

// Group is a collection of Builds than can run in parallel
type Group []Build

// Plan is collection of BuildGroups that run sequentially
type Plan []Group

type PlannerOpts struct {
	// TplData is a struct used as templating input.
	TplData *templatingdata.TemplatingData

	SourceOnly      bool
	BuildInstallers bool

	Proxy        Proxy
	BlueprintsFS fs.FS
	Paths        *testutil.Paths
	Events       testutil.EventManager
}

type Planner struct {
	Opts *PlannerOpts
}

func (b *Planner) CreateBuildPlan(paths []string) (Plan, error) {
	klog.InfoS("Constructing build plan", "paths", paths)
	var toBuild Plan

	for _, path := range paths {
		base := filepath.Base(path)
		if strings.Contains(base, "layer") {
			if layer, err := b.layer(path); err != nil {
				return nil, err
			} else {
				toBuild = append(toBuild, layer...)
			}
		} else if strings.Contains(base, "group") {
			if grp, err := b.group(path); err != nil {
				return nil, err
			} else {
				toBuild = append(toBuild, grp)
			}
		} else if strings.Contains(base, ".toml") || strings.Contains(base, ".image-fetcher") || strings.Contains(base, ".containerfile") {
			if build, err := b.file(path); err != nil {
				return nil, err
			} else if build != nil {
				toBuild = append(toBuild, Group{build})
			}
		} else if strings.Contains(base, ".image-installer") || strings.Contains(base, ".alias") {
			return nil, fmt.Errorf("passing .image-installer or .alias files directly is not supported - only .toml and .image-fetcher file are supported")
		} else {
			return nil, fmt.Errorf("unknown artifact to build: %q", path)
		}
	}

	out, err := json.MarshalIndent(toBuild, "", "    ")
	if err != nil {
		return nil, fmt.Errorf("failed to marshal build plan to json: %w", err)
	}
	klog.InfoS("Constructed build plan", "groups", len(toBuild), "plan", string(out))

	return toBuild, nil
}

func (b *Planner) layer(path string) (Plan, error) {
	klog.InfoS("Constructing build plan from provided blueprint layer", "path", path)

	entries, err := fs.ReadDir(b.Opts.BlueprintsFS, path)
	if err != nil {
		return nil, err
	}

	toBuild := make(Plan, 0, len(entries))

	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), "group") {
			if files, err := b.group(filepath.Join(path, e.Name())); err != nil {
				return nil, err
			} else if len(files) != 0 {
				toBuild = append(toBuild, files)
			}
		}
	}

	return toBuild, nil
}

func (b *Planner) group(path string) (Group, error) {
	klog.InfoS("Constructing build group from provided blueprint group", "path", path)

	entries, err := fs.ReadDir(b.Opts.BlueprintsFS, path)
	if err != nil {
		return nil, err
	}

	toBuild := make(Group, 0, len(entries))
	for _, e := range entries {
		entryPath := filepath.Join(path, e.Name())
		if e.IsDir() {
			return nil, fmt.Errorf("unexpected directory inside group: %s", entryPath)
		}

		if build, err := b.file(entryPath); err != nil {
			return nil, err
		} else if build != nil {
			toBuild = append(toBuild, build)
		}
	}

	return toBuild, nil
}

func (b *Planner) file(path string) (Build, error) {
	klog.InfoS("Creating Build", "path", path)
	filename := filepath.Base(path)

	if b.Opts.SourceOnly && !strings.Contains(filename, "source") {
		klog.InfoS("SourceOnly mode - skipping image", "path", path)
		return nil, nil
	}

	switch filepath.Ext(filename) {
	case ".image-installer", ".alias":
		// Handled by BlueprintBuild
		return nil, nil
	case ".image-fetcher":
		return b.Opts.Proxy.NewImageFetcher(path, b.Opts)
	case ".containerfile":
		return b.Opts.Proxy.NewContainerfileBuild(path, b.Opts)
	}

	return b.Opts.Proxy.NewBlueprintBuild(path, b.Opts)
}
