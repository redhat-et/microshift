package cmd

import (
	"fmt"
	"time"

	"github.com/openshift/microshift/pkg/admin"
	"github.com/openshift/microshift/pkg/config"
	"github.com/openshift/microshift/pkg/version"

	"github.com/spf13/cobra"
)

func newAdminDataCommand() *cobra.Command {
	backup := &cobra.Command{
		Use:   "backup",
		Short: "Backup MicroShift data",
		RunE: func(cmd *cobra.Command, args []string) error {
			return admin.MakeBackup(
				admin.BackupConfig{
					Target: cmd.Flag("dest").Value.String(),
					Name:   cmd.Flag("name").Value.String(),
				},
			)
		},
	}

	data := &cobra.Command{
		Use:   "data",
		Short: "Commands for managing MicroShift data",
	}
	v := version.Get()
	data.PersistentFlags().String(
		"dest",
		config.BackupsDir,
		"Directory with backups",
	)
	data.PersistentFlags().String(
		"name",
		fmt.Sprintf("%s.%s__%s", v.Major, v.Minor, time.Now().UTC().Format("20060102_150405")),
		"Backup name",
	)

	data.AddCommand(backup)
	return data
}

func NewAdminCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "admin",
		Short: "Commands for managing MicroShift",
	}
	cmd.AddCommand(newAdminDataCommand())
	return cmd
}
