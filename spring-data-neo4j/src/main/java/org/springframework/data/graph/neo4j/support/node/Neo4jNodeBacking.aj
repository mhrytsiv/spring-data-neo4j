/*
 * Copyright 2010 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.springframework.data.graph.neo4j.support.node;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;
import org.aspectj.lang.JoinPoint;
import org.aspectj.lang.reflect.FieldSignature;
import org.neo4j.graphdb.*;
import org.neo4j.graphdb.traversal.TraversalDescription;
import org.neo4j.graphdb.traversal.Traverser;
import org.springframework.data.graph.core.NodeBacked;
import org.springframework.data.graph.core.GraphBacked;
import org.springframework.data.graph.core.RelationshipBacked;
import org.springframework.data.graph.neo4j.fieldaccess.*;
import org.springframework.data.graph.neo4j.support.GraphDatabaseContext;

import java.lang.reflect.Field;
import org.springframework.data.graph.annotation.*;
import javax.persistence.Transient;
import javax.persistence.Entity;
import org.springframework.beans.factory.annotation.Configurable;


import static org.springframework.data.graph.neo4j.fieldaccess.DoReturn.unwrap;

/**
 * Aspect for handling node entity creation and field access (read & write)
 * puts the underlying state (Node) into and delegates field access to an {@link org.springframework.data.graph.neo4j.fieldaccess.EntityState} instance,
 * created by a configured {@link org.springframework.data.graph.neo4j.fieldaccess.NodeEntityStateFactory}.
 *
 * Handles constructor invocation and partial entities as well.
 */
public aspect Neo4jNodeBacking { // extends AbstractTypeAnnotatingMixinFields<NodeEntity, NodeBacked> {

    protected final Log log = LogFactory.getLog(getClass());

    declare parents : (@NodeEntity *) implements NodeBacked;
    //declare @type: NodeBacked+: @Configurable;

    declare @field: @GraphProperty * (@Entity @NodeEntity(partial=true) *).*:@Transient;
    declare @field: @RelatedTo * (@Entity @NodeEntity(partial=true) *).*:@Transient;
    declare @field: @RelatedToVia * (@Entity @NodeEntity(partial=true) *).*:@Transient;
    declare @field: @GraphId * (@Entity @NodeEntity(partial=true) *).*:@Transient;
    declare @field: @GraphTraversal * (@Entity @NodeEntity(partial=true) *).*:@Transient;



    protected pointcut entityFieldGet(NodeBacked entity) :
            get(* NodeBacked+.*) &&
            this(entity) &&
            !get(* NodeBacked.*);


    protected pointcut entityFieldSet(NodeBacked entity, Object newVal) :
            set(* NodeBacked+.*) &&
            this(entity) &&
            args(newVal) &&
            !set(* NodeBacked.*);


    private GraphDatabaseContext graphDatabaseContext;
    private NodeEntityStateFactory entityStateFactory;

    public void setGraphDatabaseContext(GraphDatabaseContext graphDatabaseContext) {
        this.graphDatabaseContext = graphDatabaseContext;
    }
    public void setNodeEntityStateFactory(NodeEntityStateFactory entityStateFactory) {
        this.entityStateFactory = entityStateFactory;
    }
    /**
     * pointcut for constructors not taking a node to be handled by the aspect and the {@link org.springframework.data.graph.neo4j.fieldaccess.EntityState}
     */
	pointcut arbitraryUserConstructorOfNodeBackedObject(NodeBacked entity) :
		execution((@NodeEntity *).new(..)) &&
		!execution((@NodeEntity *).new(Node)) &&
		this(entity) && !cflowbelow(call(* fromStateInternal(..)));


    /**
     * Handle outside entity instantiation by either creating an appropriate backing node in the graph or in the case
     * of a reinstantiated partial entity by assigning the original node to the entity, the concrete behaviour is delegated
     * to the {@link org.springframework.data.graph.neo4j.fieldaccess.EntityState}. Also handles the java type representation in the graph.
     * When running outside of a transaction, no node is created, this is handled later when the entity is accessed within
     * a transaction again.
     */
    before(NodeBacked entity): arbitraryUserConstructorOfNodeBackedObject(entity) {
        if (entityStateFactory == null) {
            log.error("entityStateFactory not set, not creating accessors for " + entity.getClass());
        } else {
            if (entity.entityState != null) return;
            entity.entityState = entityStateFactory.getEntityState(entity);
        }
    }

    /**
     * State accessors that encapsulate the underlying state and the behaviour related to it (field access, creation)
     */
    private transient EntityState<NodeBacked,Node> NodeBacked.entityState;

    public <T extends NodeBacked> T NodeBacked.persist() {
        return (T)this.entityState.persist();
    }
    public boolean NodeBacked.refersTo(GraphBacked target) {
        return this.entityState.refersTo(target);
    }

	public void NodeBacked.setPersistentState(Node n) {
        if (this.entityState == null) {
            this.entityState = Neo4jNodeBacking.aspectOf().entityStateFactory.getEntityState(this);
        }
        this.entityState.setPersistentState(n);
	}

	public Node NodeBacked.getPersistentState() {
		return this.entityState!=null ? this.entityState.getPersistentState() : null;
	}
	
    public EntityState<NodeBacked, Node> NodeBacked.getEntityState() {
        return entityState;
    }

    public boolean NodeBacked.hasPersistentState() {
        return this.entityState!=null && this.entityState.hasPersistentState();
    }

    public <T extends NodeBacked> T NodeBacked.projectTo(Class<T> targetType) {
        return (T)Neo4jNodeBacking.aspectOf().graphDatabaseContext.projectTo( this, targetType);
    }

	public Relationship NodeBacked.relateTo(NodeBacked target, String type) {
        if (target==null) throw new IllegalArgumentException("Target entity is null");
        if (type==null) throw new IllegalArgumentException("Relationshiptype is null");

        Relationship relationship=getRelationshipTo(target,type);
        if (relationship!=null) return relationship;
        return this.getPersistentState().createRelationshipTo(target.getPersistentState(), DynamicRelationshipType.withName(type));
	}

    public Relationship NodeBacked.getRelationshipTo(NodeBacked target, String type) {
        Node node = this.getPersistentState();
        Node targetNode = target.getPersistentState();
        if (node==null || targetNode==null) return null;
        Iterable<Relationship> relationships = node.getRelationships(DynamicRelationshipType.withName(type), org.neo4j.graphdb.Direction.OUTGOING);
        for (Relationship relationship : relationships) {
            if (relationship.getOtherNode(node).equals(targetNode)) return relationship;
        }
        return null;
    }

	public Long NodeBacked.getNodeId() {
        if (!hasPersistentState()) return null;
		return getPersistentState().getId();
	}

    public  <T extends NodeBacked> Iterable<T> NodeBacked.findAllByTraversal(final Class<T> targetType, TraversalDescription traversalDescription) {
        if (!hasPersistentState()) throw new IllegalStateException("No node attached to " + this);
        final Traverser traverser = traversalDescription.traverse(this.getPersistentState());
        return new NodeBackedNodeIterableWrapper<T>(traverser, targetType, Neo4jNodeBacking.aspectOf().graphDatabaseContext);
    }

    public <R extends RelationshipBacked, N extends NodeBacked> R NodeBacked.relateTo(N target, Class<R> relationshipClass, String relationshipType) {
        if (target==null) throw new IllegalArgumentException("Target entity is null");
        if (relationshipClass==null) throw new IllegalArgumentException("Relationship class is null");
        if (relationshipType==null) throw new IllegalArgumentException("Relationshiptype is null");

        Relationship rel = this.relateTo(target,relationshipType);

        GraphDatabaseContext gdc = Neo4jNodeBacking.aspectOf().graphDatabaseContext;
        gdc.postEntityCreation(rel, relationshipClass);
        return (R) gdc.createEntityFromState(rel, relationshipClass);
    }

    public void NodeBacked.remove() {
        Neo4jNodeBacking.aspectOf().graphDatabaseContext.removeNodeEntity(this);
    }

    public void NodeBacked.removeRelationshipTo(NodeBacked target, String relationshipType) {
        if (target==null) throw new IllegalArgumentException("Target entity is null");
        if (relationshipType==null) throw new IllegalArgumentException("Relationshiptype is null");

        Node node=this.getPersistentState();
        Node targetNode=target.getPersistentState();
        if (node==null || targetNode==null) return;
        for (Relationship rel : this.getPersistentState().getRelationships(DynamicRelationshipType.withName(relationshipType))) {
            if (rel.getOtherNode(node).equals(targetNode)) {
                rel.delete();
                return;
            }
        }
    }

    public <R extends RelationshipBacked> R NodeBacked.getRelationshipTo( NodeBacked target, Class<R> relationshipClass, String type) {
        if (target ==null) throw new IllegalArgumentException("Target entity is null");
        if (relationshipClass==null) throw new IllegalArgumentException("Relationship class is null");
        if (type==null) throw new IllegalArgumentException("Relationshiptype is null");
        Node node=this.getPersistentState();
        Node targetNode= target.getPersistentState();
        if (node==null || targetNode==null) return null;
        for (Relationship rel : node.getRelationships(DynamicRelationshipType.withName(type))) {
            if (rel.getOtherNode(node).equals(targetNode)) {
                return (R)Neo4jNodeBacking.aspectOf().graphDatabaseContext.createEntityFromState(rel, relationshipClass);
            }
        }
        return null;
    }

    /**
     * @param obj
     * @return result of equals operation fo the underlying node, false if there is none
     */
	public final boolean NodeBacked.equals(Object obj) {
        if (obj == this) return true;
        if (!hasPersistentState()) return false;
		if (obj instanceof NodeBacked) {
			return this.getPersistentState().equals(((NodeBacked) obj).getPersistentState());
		}
		return false;
	}

    /**
     * @return result of the hashCode of the underlying node (if any, otherwise identityHashCode)
     */
	public final int NodeBacked.hashCode() {
        if (!hasPersistentState()) return System.identityHashCode(this);
		return getPersistentState().hashCode();
	}

    /**
     * delegates field reads to the state accessors instance
     */
    Object around(NodeBacked entity): entityFieldGet(entity) {
        if (entity.entityState==null) return proceed(entity);
        Object result=entity.entityState.getValue(field(thisJoinPoint));
        if (result instanceof DoReturn) return unwrap(result);
        return proceed(entity);
    }

    /**
     * delegates field writes to the state accessors instance
     */
    Object around(NodeBacked entity, Object newVal) : entityFieldSet(entity, newVal) {
        if (entity.entityState==null) return proceed(entity,newVal);
        Object result=entity.entityState.setValue(field(thisJoinPoint),newVal);
        if (result instanceof DoReturn) return unwrap(result);
        return proceed(entity,result);
	}

    Field field(JoinPoint joinPoint) {
        FieldSignature fieldSignature = (FieldSignature)joinPoint.getSignature();
        return fieldSignature.getField();
    }
}
