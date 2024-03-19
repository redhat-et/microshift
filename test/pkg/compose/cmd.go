package compose

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

type ComposeOpts struct {
	MicroShiftRepoRootPath string
	TestDirPath            string
	ArtifactsMainDir       string

	TemplatingDataFragmentFilepath string

	Force           bool
	DryRun          bool
	BuildInstallers bool
	SourceOnly      bool
}

var (
	opts = &ComposeOpts{}
)

func NewComposeCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "compose target",
		Short: "",
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			// Add missing dynamic fields to the `opts`

			testDir := cmd.Flag("test-dir").Value.String()
			testDirAbs, err := filepath.Abs(testDir)
			if err != nil {
				return err
			}

			opts.TestDirPath = testDirAbs
			opts.MicroShiftRepoRootPath = filepath.Join(testDirAbs, "..")
			opts.ArtifactsMainDir = filepath.Join(opts.MicroShiftRepoRootPath, "_output", "test-images")

			return nil
		},
	}

	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		if len(args) != 1 {
			return fmt.Errorf("argument must be provided")
		}

		var composer Composer
		var ostree Ostree
		if opts.DryRun {
			ostree = NewDryRunOstree()
			composer = NewDryRunComposer()
		} else {
			ostree = NewOstree(filepath.Join(opts.ArtifactsMainDir, "repo"))
			composer = NewComposer(opts.TestDirPath)
		}

		td, err := NewTemplatingData(opts)
		if err != nil {
			return err
		}

		if err := NewSourceConfigurer(composer, td, opts).ConfigureSources(); err != nil {
			return err
		}

		blueprintsPath := filepath.Join(opts.TestDirPath, "image-blueprints")
		buildPlanner := BuildPlanner{
			Opts: &BuildOpts{
				ComposeOpts: opts,
				Filesys:     os.DirFS(blueprintsPath),
				TplData:     td,
				Composer:    composer,
				Ostree:      ostree,
			},
		}

		buildPath := filepath.Join(opts.TestDirPath, args[0])
		buildPath = strings.TrimLeft(strings.ReplaceAll(buildPath, blueprintsPath, ""), "/")
		toBuild, err := buildPlanner.ConstructBuildTree(buildPath)
		if err != nil {
			return err
		}

		builder := BuildRunner{}
		err = builder.Build(toBuild)
		if err != nil {
			return err
		}

		return nil
	}

	cmd.PersistentFlags().StringVar(&opts.TemplatingDataFragmentFilepath, "templating-data", "", "Provide path to partial templating data to skip querying remote repository.")
	cmd.PersistentFlags().BoolVarP(&opts.BuildInstallers, "build-installers", "I", true, "Build ISO image installers.")
	cmd.PersistentFlags().BoolVarP(&opts.SourceOnly, "source-only", "s", false, "Build only source blueprints.")
	cmd.PersistentFlags().BoolVarP(&opts.DryRun, "dry-run", "d", false, "Dry run - no real interaction with the Composer")
	cmd.PersistentFlags().BoolVarP(&opts.Force, "force", "f", false, "Rebuild existing artifacts (ostree commits, ISO images)")

	cmd.AddCommand(templatingDataSubCmd())

	return cmd
}

func templatingDataSubCmd() *cobra.Command {
	full := false

	cmd := &cobra.Command{
		Use:   "templating-data",
		Short: "",
		RunE: func(cmd *cobra.Command, args []string) error {
			td, err := NewTemplatingData(opts)
			if err != nil {
				return err
			}

			// Only serialize entire templating data if requested.
			if full {
				b, err := json.MarshalIndent(td, "", "    ")
				if err != nil {
					return fmt.Errorf("failed to marshal templating data to json: %w", err)
				}
				fmt.Printf("%s", string(b))
				return nil
			}

			// By default this will only include information that change less often (i.e. RHOCP and OpenShift mirror related) and take longer to obtain.
			// Information obtained from local files is quick and can change more often.
			reducedTD := make(map[string]interface{})
			reducedTD["Current"] = td.Current
			reducedTD["Previous"] = td.Previous
			reducedTD["YMinus2"] = td.YMinus2
			reducedTD["RHOCPMinorY"] = td.RHOCPMinorY
			reducedTD["RHOCPMinorY1"] = td.RHOCPMinorY1
			reducedTD["RHOCPMinorY2"] = td.RHOCPMinorY2
			b, err := json.MarshalIndent(reducedTD, "", "    ")
			if err != nil {
				return fmt.Errorf("failed to marshal reduced templating data to json: %w", err)
			}
			fmt.Printf("%s", string(b))

			return nil
		},
	}

	cmd.Flags().BoolVar(&full, "full", false, "Obtain full templating data, including local RPM information (source, base, fake)")

	return cmd
}
