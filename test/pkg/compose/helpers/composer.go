package helpers

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/osbuild/weldr-client/v2/weldr"
	"k8s.io/klog/v2"
)

type Composer interface {
	ListSources() ([]string, error)
	DeleteSource(id string) error
	AddSource(toml string) error

	AddBlueprint(toml string) error
	DepsolveBlueprint(name string) error

	StartOSTreeCompose(blueprint, composeType, ref, parent string) (string, error)
	StartCompose(blueprint, composeType string) (string, error)

	WaitForCompose(id, friendlyName string, timeout time.Duration) error

	SaveComposeLogs(id, friendlyName string) error
	SaveComposeMetadata(id, friendlyName string) error
	SaveComposeImage(id, friendlyName, ext string) (string, error)
}

var _ Composer = (*composer)(nil)

type composer struct {
	client        weldr.Client
	ostreeRepoURL string

	logsDir   string
	buildsDir string
}

func NewComposer(testDirPath string, ostreeRepoURL string) (Composer, error) {
	artifactsDir := filepath.Join(testDirPath, "..", "_output", "test-images")
	logsDir := filepath.Join(artifactsDir, "build-logs")
	buildsDir := filepath.Join(artifactsDir, "builds")

	if err := os.MkdirAll(logsDir, 0755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(buildsDir, 0755); err != nil {
		return nil, err
	}

	// TODO: Check if ostree http repo is up

	return &composer{
		client:        weldr.InitClientUnixSocket(context.Background(), 1, "/run/weldr/api.socket"),
		ostreeRepoURL: ostreeRepoURL,

		logsDir:   logsDir,
		buildsDir: buildsDir,
	}, nil
}

func (c *composer) ListSources() ([]string, error) {
	klog.InfoS("Listing Composer Sources")
	sources, apiResponse, err := c.client.ListSources()
	if err != nil {
		return nil, fmt.Errorf("listing composer sources failed: %w", err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return nil, fmt.Errorf("listing composer sources returned wrong response: %v", apiResponse)
	}
	klog.InfoS("Listed Composer Sources", "sources", sources)
	return sources, nil
}

func (c *composer) DeleteSource(id string) error {
	klog.InfoS("Deleting Composer Source", "id", id)
	apiResponse, err := c.client.DeleteSource(id)
	if err != nil {
		return fmt.Errorf("deleting composer source failed: %w", err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return fmt.Errorf("deleting composer source returned wrong response: %v", apiResponse)
	}
	klog.InfoS("Deleted Composer Source", "id", id)
	return nil
}

func (c *composer) AddSource(toml string) error {
	short := strings.ReplaceAll(toml[:50], "\n", "") + "..."
	klog.InfoS("Adding Composer Source", "toml", short)
	apiResponse, err := c.client.NewSourceTOML(toml)
	if err != nil {
		return fmt.Errorf("adding composer source failed: %w", err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return fmt.Errorf("adding composer source returned wrong response: %v", apiResponse)
	}
	klog.InfoS("Added Composer Source", "toml", short)
	return nil
}

func (c *composer) AddBlueprint(toml string) error {
	short := strings.ReplaceAll(toml[:50], "\n", "") + "..."
	klog.InfoS("Adding Composer Blueprint", "toml", short)
	apiResponse, err := c.client.PushBlueprintTOML(toml)
	if err != nil {
		return fmt.Errorf("adding composer blueprint failed: %w", err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return fmt.Errorf("adding composer blueprint returned wrong response: %v", apiResponse)
	}
	klog.InfoS("Added Composer Blueprint", "toml", short)
	return nil
}

func (c *composer) DepsolveBlueprint(name string) error {
	klog.InfoS("Depsolving blueprint", "name", name)
	blueprints, apiErrors, err := c.client.DepsolveBlueprints([]string{name})

	// TODO: Write to file
	_ = blueprints

	if err != nil {
		return fmt.Errorf("error depsolving blueprint %q: %w", name, err)
	}
	if len(apiErrors) != 0 {
		return fmt.Errorf("unsuccessful blueprint depsolve: %+v", apiErrors)
	}

	klog.InfoS("Depsolved blueprint", "name", name)

	return nil
}

func (c *composer) StartOSTreeCompose(blueprint, composeType, ref, parent string) (string, error) {
	url := ""
	if parent != "" {
		url = c.ostreeRepoURL
	}
	klog.InfoS("Starting ostree compose", "blueprint", blueprint, "type", composeType, "ref", ref, "parent", parent, "url", url)
	id, apiResponse, err := c.client.StartOSTreeCompose(blueprint, composeType, ref, parent, url, 0)
	if err != nil {
		return "", fmt.Errorf("error starting ostree compose: %w", err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return "", fmt.Errorf("unsuccessful compose start: %+v", apiResponse)
	}
	klog.InfoS("Started ostree compose", "blueprint", blueprint, "id", id)

	return id, nil
}

func (c *composer) StartCompose(blueprint, composeType string) (string, error) {
	klog.InfoS("Starting compose", "blueprint", blueprint, "type", composeType)
	id, apiResponse, err := c.client.StartCompose(blueprint, composeType, 0)
	if err != nil {
		return "", fmt.Errorf("error starting ostree compose: %w", err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return "", fmt.Errorf("unsuccessful compose start: %+v", apiResponse)
	}
	klog.InfoS("Started compose", "blueprint", blueprint, "id", id)
	return id, nil
}

func (c *composer) WaitForCompose(id, friendlyName string, timeout time.Duration) error {
	start := time.Now()

	var aborted bool
	var info weldr.ComposeInfoV0
	var apiResponse *weldr.APIResponse
	var err error

	done := make(chan struct{})
	go func() {
		aborted, info, apiResponse, err = c.client.ComposeWait(id, timeout, 30*time.Second)
		done <- struct{}{}
	}()

	ticker := time.NewTicker(time.Second * 30)
outer:
	for {
		select {
		case <-done:
			break outer
		case <-ticker.C:
			klog.InfoS("Waiting for compose", "id", id, "timeout", timeout, "friendlyName", friendlyName, "elapsed", time.Since(start))
		}
	}
	ticker.Stop()

	klog.InfoS("Wait for compose complete", "id", id, "timeout", timeout, "friendlyName", friendlyName, "elapsed", time.Since(start))

	// info should always be set, even if compose failed
	infoJson, infoErr := json.MarshalIndent(info, "", "    ")
	if infoErr != nil {
		return fmt.Errorf("failed to marshal compose info: %w", err)
	}
	infoFilepath := filepath.Join(c.logsDir, friendlyName+"_info.log")
	infoErr = os.WriteFile(infoFilepath, infoJson, 0644)
	if infoErr != nil {
		return fmt.Errorf("failed to write compose info to file: %w", infoErr)
	}

	if err != nil {
		return fmt.Errorf("failed to wait for the compose %q: %w", id, err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return fmt.Errorf("unsuccessful compose wait: %+v", apiResponse)
	}
	if aborted {
		return fmt.Errorf("wait for compose %q timed out", id)
	}
	return nil
}

func (c *composer) SaveComposeLogs(id, friendlyName string) error {
	klog.InfoS("Saving compose logs archive", "id", id, "friendlyName", friendlyName)

	archiveFilepath := filepath.Join(c.logsDir, friendlyName+".tar")
	logFilepath := filepath.Join(c.logsDir, friendlyName+".log")

	err := os.RemoveAll(archiveFilepath)
	if err != nil {
		return fmt.Errorf("failed to remove existing %q before downloading it: %w", archiveFilepath, err)
	}

	filename, apiResponse, err := c.client.ComposeLogsPath(id, archiveFilepath)
	if err != nil {
		return fmt.Errorf("failed to get compose's %q logs: %w", id, err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return fmt.Errorf("unsuccessful get compose's %q logs: %w", id, err)
	}

	klog.InfoS("Saved compose logs archive", "id", id, "path", filename)

	err = extractSingleFileFromTar(archiveFilepath, logFilepath)
	if err != nil {
		return err
	}

	return nil
}

func (c *composer) SaveComposeMetadata(id, friendlyName string) error {
	klog.InfoS("Getting compose metadata", "id", id, "friendlyName", friendlyName)

	archiveFilepath := filepath.Join(c.logsDir, friendlyName+"_metadata.tar")
	logFilepath := filepath.Join(c.logsDir, friendlyName+"_metadata.log")

	err := os.RemoveAll(archiveFilepath)
	if err != nil {
		return fmt.Errorf("failed to remove existing %q before downloading it: %w", archiveFilepath, err)
	}

	filename, apiResponse, err := c.client.ComposeMetadataPath(id, archiveFilepath)
	if err != nil {
		return fmt.Errorf("failed to get compose's %q metadata: %w", id, err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return fmt.Errorf("unsuccessful get compose's %q metadata: %w", id, err)
	}

	klog.InfoS("Got compose metadata", "id", id, "filename", filename)

	err = extractSingleFileFromTar(archiveFilepath, logFilepath)
	if err != nil {
		return err
	}

	return nil
}

func (c *composer) SaveComposeImage(id, friendlyName, ext string) (string, error) {
	klog.InfoS("Getting compose image", "id", id, "friendlyName", friendlyName, "ext", ext)

	path := filepath.Join(c.buildsDir, friendlyName+ext)
	err := os.RemoveAll(path)
	if err != nil {
		return "", fmt.Errorf("failed to remove existing %q before downloading it: %w", path, err)
	}

	filename, apiResponse, err := c.client.ComposeImagePath(id, path)
	if err != nil {
		return "", fmt.Errorf("failed to get compose's %q image: %w", id, err)
	}
	if apiResponse != nil && !apiResponse.Status {
		return "", fmt.Errorf("unsuccessful get compose's %q image: %w", id, err)
	}

	klog.InfoS("Got compose image", "id", id, "filename", filename)
	return filename, nil
}
