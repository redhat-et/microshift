package migration

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	crdclient "k8s.io/apiextensions-apiserver/pkg/client/clientset/clientset"
	v1 "k8s.io/apiextensions-apiserver/pkg/client/clientset/clientset/typed/apiextensions/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/retry"
	apiserviceclient "k8s.io/kube-aggregator/pkg/client/clientset_generated/clientset"
	apiregistrationv1 "k8s.io/kube-aggregator/pkg/client/clientset_generated/clientset/typed/apiregistration/v1"

	"k8s.io/klog/v2"
)

var excludeResources = sets.NewString(
	"events",
)

var metadataAccessor = meta.NewAccessor()

type migrator struct {
	client           dynamic.Interface
	discoveryClient  discovery.ServerResourcesInterface
	crdClient        v1.CustomResourceDefinitionInterface
	apiserviceClient apiregistrationv1.APIServiceInterface
}

func NewMigrator(kubeConfigPath string) (*migrator, error) {
	restConfig, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
	if err != nil {
		return nil, fmt.Errorf("failed to build rest config: %w", err)
	}
	clientset, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to build kubernetes clientset config: %w", err)
	}
	crd, err := crdclient.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to build crd clientset config: %w", err)
	}
	apiservice, err := apiserviceclient.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to build apiservice client config: %w", err)
	}
	dynamic, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to build dynamic client config: %w", err)
	}

	return &migrator{
		client:           dynamic,
		discoveryClient:  clientset.Discovery(),
		crdClient:        crd.ApiextensionsV1().CustomResourceDefinitions(),
		apiserviceClient: apiservice.ApiregistrationV1().APIServices(),
	}, nil
}

func (d *migrator) Start(ctx context.Context) (*MigrationResultList, error) {
	return d.start(ctx)
}

func (d *migrator) start(ctx context.Context) (*MigrationResultList, error) {
	schemas, err := d.findMigratableResources(ctx)
	if err != nil {
		return nil, err
	}
	results := &MigrationResultList{
		Status: MigrationSuccess,
	}
	errorOccured := false
	start := time.Now()
	klog.Info("schema migration started")

	wg := sync.WaitGroup{}
	lock := sync.Mutex{}
	wg.Add(len(schemas))
	for _, sch := range schemas {
		go func(wg *sync.WaitGroup, sch schema.GroupVersionResource) {
			defer wg.Done()
			objectList := &unstructured.UnstructuredList{}

			migrationErr := retry.OnError(retry.DefaultBackoff, canRetry, func() error {
				var err error
				objectList, err = d.client.Resource(sch).Namespace(metav1.NamespaceAll).List(ctx, metav1.ListOptions{})
				if err != nil {
					return err
				}
				return nil
			})

			if migrationErr != nil {
				errorOccured = true
				migrationErr = fmt.Errorf("could not list resources: %+v", migrationErr)
				lock.Lock()
				defer lock.Unlock()
				results.Items = append(results.Items, MigrationResult{Error: migrationErr, ResourceVersion: sch, Timestamp: time.Now()})
				return
			}

			localResults := &MigrationResultList{Status: MigrationSuccess}
			for _, object := range objectList.Items {
				ref := object
				migrationErr := d.migrateOneItem(ctx, sch, &ref)
				if migrationErr != nil {
					errorOccured = true
				}
				localResults.Items = append(localResults.Items, MigrationResult{
					Error:           migrationErr,
					ResourceVersion: sch,
					NamespacedName:  getNamespacedName(&ref),
					Timestamp:       time.Now()})
			}

			lock.Lock()
			defer lock.Unlock()
			results.Items = append(results.Items, localResults.Items...)
		}(&wg, sch)
	}
	wg.Wait()
	if errorOccured {
		results.Status = MigrationFailure
	}
	klog.InfoS("schema migration finished", "duration", time.Since(start).String())
	return results, nil
}

// findMigratableResources finds all the resources that potentially need
// migration. Although all migratable resources are accessible via multiple
// versions, the returned list only include one version.
//
// It builds the list in these steps:
// 1. build a map from resource name to the groupVersions, excluding subresources, custom resources, or aggregated resources.
// 2. exclude all the resource that is only available from one groupVersions.
// 3. exclude the resource that does not support "list" and "update" (thus not migratable).
//
// More information can be found here:
// https://github.com/kubernetes-sigs/kube-storage-version-migrator/blob/acdee30ced218b79e39c6a701985e8cd8bd33824/pkg/initializer/discover.go#L55-L125
func (d *migrator) findMigratableResources(ctx context.Context) ([]schema.GroupVersionResource, error) {
	customGroups, err := d.findCustomGroups(ctx)
	if err != nil {
		return nil, err
	}
	aggregatedGroups, err := d.findAggregatedGroups(ctx)
	if err != nil {
		return nil, err
	}
	resourceToGroupVersions := make(map[string][]schema.GroupVersion)
	_, resourceLists, err := d.discoveryClient.ServerGroupsAndResources()
	if err != nil {
		return nil, err
	}
	for _, resourceList := range resourceLists {
		gv, err := schema.ParseGroupVersion(resourceList.GroupVersion)
		if err != nil {
			klog.ErrorS(err, "cannot parse group version, ignored", "groupVersion", resourceList.GroupVersion)
			continue
		}
		if customGroups.Has(gv.Group) {
			klog.InfoS("ignored because it's a custom group", "group", gv.Group)
			continue
		}
		if aggregatedGroups.Has(gv.Group) {
			klog.InfoS("ignored because it's an aggregated group", "group", gv.Group)
			continue
		}
		for _, r := range resourceList.APIResources {
			// ignore subresources
			if strings.Contains(r.Name, "/") {
				continue
			}
			// ignore excluded resources
			if excludeResources.Has(r.Name) {
				continue
			}
			// ignore resources that cannot be listed and updated
			if !sets.NewString(r.Verbs...).HasAll("list", "update") {
				continue
			}
			gvs := resourceToGroupVersions[r.Name]
			gvs = append(gvs, gv)
			resourceToGroupVersions[r.Name] = gvs
		}
	}

	ret := []schema.GroupVersionResource{}
	for resource, groupVersions := range resourceToGroupVersions {
		// if a resource only has one version, no migration is required
		// resources that have more than one version are eligible for migration.
		if len(groupVersions) == 1 {
			continue
		}
		ret = append(ret, groupVersions[0].WithResource(resource))
	}
	return ret, nil
}

func (m *migrator) migrateOneItem(ctx context.Context, resource schema.GroupVersionResource, item *unstructured.Unstructured) error {
	namespace, err := metadataAccessor.Namespace(item)
	if err != nil {
		return err
	}
	name, err := metadataAccessor.Name(item)
	if err != nil {
		return err
	}
	getBeforePut := false
	for {
		getBeforePut, err = m.try(ctx, resource, namespace, name, item, getBeforePut)
		if err == nil || errors.IsNotFound(err) {
			return nil
		}
		if canRetry(err) {
			seconds, delay := errors.SuggestsClientDelay(err)
			klog.ErrorS(err, "migration of an object will be retried", "name", name, "namespace", namespace, "delay", seconds)
			if delay {
				time.Sleep(time.Duration(seconds) * time.Second)
			}
			continue
		}
		// error is not retriable
		return fmt.Errorf("can not retry: %+v", err)
	}
}

func (m *migrator) try(ctx context.Context, resource schema.GroupVersionResource, namespace, name string, item *unstructured.Unstructured, get bool) (bool, error) {
	var err error
	if get {
		item, err = m.client.
			Resource(resource).
			Namespace(namespace).
			Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return true, err
		}
	}
	_, err = m.client.
		Resource(resource).
		Namespace(namespace).
		Update(ctx, item, metav1.UpdateOptions{})
	if err == nil {
		return false, nil
	}
	return errors.IsConflict(err), err
}

func (d *migrator) findCustomGroups(ctx context.Context) (sets.Set[string], error) {
	ret := sets.New[string]()
	l, err := d.crdClient.List(ctx, metav1.ListOptions{})
	if err != nil {
		return ret, err
	}
	for _, crd := range l.Items {
		ret.Insert(crd.Spec.Group)
	}
	return ret, nil
}

func (d *migrator) findAggregatedGroups(ctx context.Context) (sets.Set[string], error) {
	ret := sets.New[string]()
	l, err := d.apiserviceClient.List(ctx, metav1.ListOptions{})
	if err != nil {
		return ret, err
	}
	for _, apiservice := range l.Items {
		if apiservice.Spec.Service != nil {
			ret.Insert(apiservice.Spec.Group)
		}
	}
	return ret, nil
}
