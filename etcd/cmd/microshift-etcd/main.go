package main

import (
	"os"

	"github.com/spf13/cobra"
	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/component-base/cli"
	"k8s.io/component-base/logs"
	"go.etcd.io/etcd/etcdctl/v3/ctlv3"
)

func main() {
	logs.InitLogs()
	defer logs.FlushLogs()

	cmd := &cobra.Command{
		Use: "microshift-etcd",
		Run: func(cmd *cobra.Command, args []string) {
			cmd.Help()
			os.Exit(1)
		},
	}
	cmd.AddCommand(NewRunEtcdCommand())
	cmd.AddCommand(NewVersionCommand(genericclioptions.IOStreams{In: os.Stdin, Out: os.Stdout, ErrOut: os.Stderr}))
	// Enable etcdctl subcommands
	cmd.AddCommand(ctlv3.RootCmd.Commands()...)
	cmd.PersistentFlags().AddFlagSet(ctlv3.RootCmd.PersistentFlags())
	os.Exit(cli.Run(cmd))
}
